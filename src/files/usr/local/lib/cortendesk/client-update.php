<?php
// client-update.php -- self-update links for Windows clients built by rdgen (nginx: /etc/nginx/rustdesk-clients.conf).
//   GET/HEAD /clients/<windows-x86_64|windows-x86>/<RustDesk version the client runs>/<configuration>.exe
// Redirects (302) to CortenDesk's own /downloads/<id> for the newest PUBLISHED rdgen build of <configuration>.exe for
// that architecture whose RustDesk version is newer than the one in the link, else 404. RustDesk's auto-update
// fires when the official release is newer than the client; the version in the link keeps a client from reinstalling
// the build it already runs. Runs under PHP-FPM as the app user and only reads the database.
header('Cache-Control: no-store');
$arch = ['windows-x86_64' => 'x86_64', 'windows-x86' => 'x86'][(string) ($_SERVER['RD_ARCH'] ?? '')] ?? null;
$ver = (string) ($_SERVER['RD_VERSION'] ?? '');
$cfg = (string) ($_SERVER['RD_CONFIG'] ?? '');
$semver = '/^\d{1,3}\.\d{1,3}\.\d{1,3}$/';
if ($arch === null || ! preg_match($semver, $ver) || ! preg_match('/^[A-Za-z0-9_-]{1,64}$/', $cfg)) {
    http_response_code(404);
    exit;
}
$db = '/var/lib/cortendesk/cortendesk.sqlite';
foreach (@file('/etc/cortendesk/cortendesk.env', FILE_IGNORE_NEW_LINES) ?: [] as $line) {
    if (str_starts_with($line, 'DB_DATABASE=')) {
        $db = trim(substr($line, strlen('DB_DATABASE=')), "\"' ");
    }
}
try {
    $pdo = new PDO('sqlite:'.$db, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::SQLITE_ATTR_OPEN_FLAGS => PDO::SQLITE_OPEN_READONLY]);
    $q = $pdo->prepare("SELECT id, version FROM client_downloads WHERE is_published = 1 AND platform = 'windows'
        AND arch = ? AND original_name = ? AND notes LIKE 'rdgen build %'");
    $q->execute([$arch, $cfg.'.exe']);
    $best = null;
    foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $v = (string) $row['version'];
        if (! preg_match($semver, $v) || version_compare($v, $ver, '<=')) {
            continue;   // nightly builds, and anything not newer than what the client runs
        }
        if ($best === null || version_compare($v, $best['version'], '>')
                || ($v === $best['version'] && (int) $row['id'] > (int) $best['id'])) {
            $best = $row;
        }
    }
} catch (Throwable $e) {
    error_log('client-update: '.$e->getMessage());
    http_response_code(503);
    exit;
}
if ($best === null) {
    http_response_code(404);
    exit;
}
header('Location: /downloads/'.(int) $best['id'], true, 302);
