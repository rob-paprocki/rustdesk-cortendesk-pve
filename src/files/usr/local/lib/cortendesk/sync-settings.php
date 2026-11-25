<?php
// sync-settings.php -- keep CortenDesk's database settings in step with .env. Run as the app user (cortendesk).
// Saving the Settings page writes id_server / relay_server / public_key / rdgen_url rows, and a row wins
// over .env; so when rustdesk-config changes .env, existing rows get the same value (missing rows stay
// missing, so .env keeps applying). stdin: JSON object {"id_server": "...", ...}
$base = getenv('CORTENDESK_DIR') ?: '/opt/cortendesk';
chdir($base);
require $base.'/vendor/autoload.php';
$app = require $base.'/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

$allowed = ['id_server', 'relay_server', 'public_key', 'rdgen_url'];
$in = json_decode(stream_get_contents(STDIN), true);
if (! is_array($in)) { fwrite(STDERR, "expected a JSON object on stdin\n"); exit(2); }
// "was": {key: the .env value before}. A row that differs from it was saved by hand in Settings: keep it.
$was = is_array($in['was'] ?? null) ? $in['was'] : [];
foreach ($in as $key => $value) {
    if (! in_array($key, $allowed, true) || ! is_string($value)) { continue; }
    $row = App\Models\Setting::query()->find($key);
    if ($row === null) { continue; }
    if (is_string($was[$key] ?? null) && rtrim((string) $row->value, '/') !== rtrim($was[$key], '/')) {
        echo "kept setting $key (saved in Settings: {$row->value})\n";
        continue;
    }
    App\Models\Setting::put($key, $key === 'rdgen_url' ? rtrim($value, '/') : trim($value));
    echo "updated setting $key\n";
}
