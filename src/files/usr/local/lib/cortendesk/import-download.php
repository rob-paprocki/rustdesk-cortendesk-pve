<?php
// import-download.php -- add one finished rdgen build file to CortenDesk's Client Downloads. Run by rdgen-publish
// as the app user (cortendesk) from /opt/cortendesk.
// stdin: one JSON line {uuid, label, version, filename, platform, publish, name, size, sha256} (rdgen's record of
// the build), then the file's bytes. The bytes must match rdgen's size and sha256.
// The row is hidden or published as asked. A published row hides earlier imports of the same file (same name,
// platform and architecture, from other rdgen builds) and takes their place in the list. Rows already imported from this build are not duplicated.
// Exit 0 imported (or already there), 2 invalid input, 3 a file type CortenDesk does not accept, 1 other errors.
use App\Models\ClientDownload;
use App\Models\ConsoleAudit;
use App\Support\ClientPlatform;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

$base = getenv('CORTENDESK_DIR') ?: '/opt/cortendesk';
chdir($base);
require $base.'/vendor/autoload.php';
$app = require $base.'/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

function fail(int $code, string $msg): never { fwrite(STDERR, $msg."\n"); exit($code); }

$m = json_decode((string) fgets(STDIN, 8192), true);
if (! is_array($m)) { fail(2, 'the first line is not a JSON object'); }
$str = fn (string $k) => is_string($m[$k] ?? null) ? $m[$k] : '';
$uuid = $str('uuid'); $name = $str('name'); $exe = $str('filename'); $sha = $str('sha256');
$size = $m['size'] ?? null; $publish = $str('publish'); $rdPlatform = $str('platform');
if (! preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/', $uuid)) { fail(2, 'bad build uuid'); }
if (! preg_match('/^[A-Za-z0-9_-]{1,64}$/', $exe)) { fail(2, 'bad configuration name'); }
if (! preg_match('/^[A-Za-z0-9][A-Za-z0-9._+-]{0,200}$/', $name) || str_contains($name, '..') || ! str_starts_with($name, $exe)) {
    fail(2, 'bad file name');
}
if (! preg_match('/^[0-9a-f]{64}$/', $sha)) { fail(2, 'bad sha256'); }
if (! is_int($size) || $size < 1 || $size > 4 * 1024 ** 3) { fail(2, 'bad size'); }
if (! in_array($publish, ['hidden', 'published'], true)) { fail(2, 'bad publish choice'); }
if (! ClientPlatform::extensionAllowed($name)) { fail(3, "CortenDesk does not accept .".ClientPlatform::extension($name)." files"); }

// "Acme Support (64-bit, .deb, unattended Wayland)": the platform is the heading on the downloads page
$label = trim(preg_replace('/[\x00-\x1f\x7f]+/u', ' ', $str('label'))) ?: $exe;
$label = mb_substr($label, 0, 70);
$version = $str('version') === 'master' ? 'nightly' : $str('version');
$version = preg_match('/^[A-Za-z0-9._-]{1,32}$/', $version) ? $version : null;
$platform = ClientPlatform::fromFilename($name);
$ext = ClientPlatform::extension($name);
$suffix = strtolower(substr($name, strlen($exe)));          // e.g. "-suse-aarch64.rpm"
$arch = match ($rdPlatform) {
    'windows' => 'x86_64',
    'windows-x86' => 'x86',
    default => ClientPlatform::archFromFilename($suffix),
};
$extra = array_values(array_filter(
    preg_split('/[-.]+/', substr($suffix, 0, -strlen($ext) - 1)),
    fn ($t) => $t !== '' && ClientPlatform::archFromFilename($t) === null && ! in_array($t, ['pkg', 'tar'], true)
));
$extra = array_map(fn ($t) => ['suse' => 'SUSE', 'wayland' => 'Wayland'][$t] ?? $t, $extra);
$parts = array_filter([$arch ? ClientPlatform::archLabel($arch) : '', '.'.$ext, implode(' ', $extra)]);
$label .= ' ('.implode(', ', $parts).')';
$tag = 'rdgen build '.substr($uuid, 0, 8);
$notes = $tag.' · RustDesk '.($version ?? '?').' · '.$name;

$existing = ClientDownload::where('original_name', $name)->where('sha256', $sha)->where('notes', 'like', $tag.' %')->first();
if ($existing !== null) {
    echo json_encode(['id' => $existing->id, 'published' => $existing->is_published, 'label' => $existing->label,
        'existing' => true])."\n";
    exit(0);
}

$disk = Storage::disk(ClientDownload::DISK);
$tmp = $disk->path('.rdgen-'.Str::random(16).'.part');
$out = @fopen($tmp, 'x');   // 'x': never follows or reuses an existing path
if ($out === false) { fail(1, 'cannot create a file in the downloads directory'); }
$ctx = hash_init('sha256');
$n = 0;
while (! feof(STDIN)) {
    $buf = fread(STDIN, 1 << 20);
    if ($buf === false) { break; }
    $n += strlen($buf);
    if ($n > $size) { fclose($out); @unlink($tmp); fail(1, "more data than rdgen recorded ({$size} bytes)"); }
    hash_update($ctx, $buf);
    if (fwrite($out, $buf) !== strlen($buf)) { fclose($out); @unlink($tmp); fail(1, 'write failed (disk full?)'); }
}
fclose($out);
if ($n !== $size || ! hash_equals($sha, hash_final($ctx))) {
    @unlink($tmp);
    fail(1, "the file does not match rdgen's record ({$n} of {$size} bytes, or a different sha256)");
}
// same naming as the console's uploader: slug + random + extension, unique
$stored = Str::limit(Str::slug(pathinfo($name, PATHINFO_FILENAME)) ?: 'client', 80, '').'-'.Str::random(8).'.'.$ext;
if (! rename($tmp, $disk->path($stored))) { @unlink($tmp); fail(1, 'rename failed'); }

$audit = fn (string $action, string $summary, int $id) => ConsoleAudit::create(['user_id' => null, 'username' => 'rdgen',
    'action' => $action, 'target_type' => 'client_download', 'target_id' => (string) $id, 'summary' => $summary, 'ip' => null]);
try {
    [$row, $retired] = DB::transaction(function () use ($name, $tag, $label, $platform, $arch, $version, $notes,
            $stored, $size, $sha, $publish, $audit) {
        // windows and windows-x86 builds share the name F.exe: only the same architecture is replaced
        $old = $publish === 'published'
            ? ClientDownload::where('original_name', $name)->where('platform', $platform)
                ->where(fn ($q) => $arch === null ? $q->whereNull('arch') : $q->where('arch', $arch))
                ->where('is_published', true)->where('notes', 'like', 'rdgen build %')->orderBy('sort_order')->get()
            : collect();
        $row = ClientDownload::create([
            'label' => $label, 'platform' => $platform, 'arch' => $arch, 'version' => $version, 'notes' => $notes,
            'filename' => $stored, 'original_name' => $name, 'size' => $size, 'sha256' => $sha,
            'is_published' => $publish === 'published',
            'sort_order' => $old->isNotEmpty() ? $old->first()->sort_order : (int) ClientDownload::max('sort_order') + 1,
            'uploaded_by' => null,
        ]);
        $audit('client_download.create', "Imported {$name} from {$tag} (".($row->is_published ? 'published' : 'hidden').')', $row->id);
        foreach ($old as $o) {
            $o->is_published = false;
            $o->save();
            $audit('client_download.unpublish', "Hid {$o->original_name} (replaced by the newer {$tag})", $o->id);
        }
        return [$row, $old->pluck('id')->all()];
    });
} catch (Throwable $e) {
    $disk->delete($stored);
    fail(1, 'database: '.$e->getMessage());
}
echo json_encode(['id' => $row->id, 'published' => $row->is_published, 'label' => $row->label, 'retired' => $retired])."\n";
