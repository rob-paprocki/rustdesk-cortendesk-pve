<?php
// alert-relay.php -- a local stand-in for an Apprise API server, so CortenDesk's own alerts can go wherever
// rustdesk-notify sends (a Discord webhook, Apprise URLs). CortenDesk (Settings > Notifications, config-key mode)
// posts to http://127.0.0.1:8296/notify/<key> (nginx: /etc/nginx/rustdesk-alert-relay.conf); each alert is queued in
// /var/spool/cortendesk-alerts and cortendesk-alerts (root, every minute) sends it. The web app never reads the
// notification settings, which are root-only.
// Runs as cortendesk (php-fpm). Only nginx on 127.0.0.1 reaches it, and the path must carry the relay key.
const SPOOL = '/var/spool/cortendesk-alerts';
const KEY_FILE = '/etc/cortendesk/alert-relay.key';
const MAX_QUEUED = 200;

function reply(int $code, string $status): never
{
    http_response_code($code);
    header('Content-Type: application/json');
    echo json_encode(['status' => $status]);
    exit;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    reply(405, 'POST only');
}
$key = trim((string) @file_get_contents(KEY_FILE));
$path = (string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? ''), PHP_URL_PATH);
if ($key === '' || ! preg_match('#^/notify/([A-Za-z0-9_-]{16,128})/?$#', $path, $m) || ! hash_equals($key, $m[1])) {
    reply(404, 'unknown key');
}
$in = json_decode((string) file_get_contents('php://input', false, null, 0, 65536), true);
if (! is_array($in)) {
    reply(400, 'JSON body expected');
}
$str = fn ($v) => is_string($v) ? $v : '';
$title = mb_substr(trim((string) preg_replace('/\s+/u', ' ', $str($in['title'] ?? ''))), 0, 200);
$body = mb_substr(trim(str_replace("\r", '', $str($in['body'] ?? ''))), 0, 3000);
$type = in_array($in['type'] ?? '', ['info', 'success', 'warning', 'failure'], true) ? $in['type'] : 'info';
if ($title === '' && $body === '') {
    reply(400, 'empty message');
}
if (count(glob(SPOOL.'/*.alert') ?: []) >= MAX_QUEUED) {
    reply(503, 'queue full');
}
// one file per alert: type, title, then the body; written aside and renamed, so the sender never sees half a file
$name = sprintf('%s/%d-%s', SPOOL, (int) (microtime(true) * 1000), bin2hex(random_bytes(6)));
if (file_put_contents($name.'.tmp', $type."\n".($title !== '' ? $title : 'CortenDesk')."\n".$body."\n") === false
    || ! rename($name.'.tmp', $name.'.alert')) {
    @unlink($name.'.tmp');
    reply(500, 'could not queue the alert');
}
reply(200, 'queued');
