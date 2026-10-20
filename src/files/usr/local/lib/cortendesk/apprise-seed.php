<?php
// apprise-seed.php -- point CortenDesk's own Apprise notifications at an Apprise API server (or at the local relay,
// cortendesk-alerts). Run as the app user (cortendesk).
// stdin (JSON, never argv): {"endpoint":"http://apprise.lan:8000","key":"mykey"}            (config-key mode)
//                       or: {"endpoint":"http://apprise.lan:8000","urls":["discord://id/token"]} (stateless urls mode)
// optional "events":[...] (keys of AppriseNotifications::EVENTS): switched on only when no event is on yet, so
//          choices made under Settings > Notifications survive a re-run
// optional "if_unset":true: leave an endpoint that points somewhere else alone (prints skipped=other), and do nothing
//          when this endpoint and key are already set (prints skipped=same)
$base = getenv('CORTENDESK_DIR') ?: '/opt/cortendesk';
chdir($base); require $base.'/vendor/autoload.php';
$app = require $base.'/bootstrap/app.php'; $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
use App\Models\Setting; use Illuminate\Support\Facades\Crypt;
$in = json_decode(stream_get_contents(STDIN), true) ?: [];
$ep = trim((string) ($in['endpoint'] ?? ''));
if (! preg_match('#^https?://#i', $ep)) { fwrite(STDERR, "endpoint must be http(s)://...\n"); exit(2); }
$secret = function (string $k): string {
    $v = (string) (Setting::get($k, '') ?? '');
    try { return $v === '' ? '' : Crypt::decryptString($v); } catch (Throwable) { return ''; }
};
if (! empty($in['if_unset'])) {
    $current = $secret('apprise_endpoint');
    if ($current !== '' && $current !== $ep) { echo "skipped=other\n"; exit(0); }
    if ($current === $ep && empty($in['urls']) && $secret('apprise_config_key') === (string) ($in['key'] ?? '')
        && Setting::get('apprise_delivery_mode', 'config') === 'config') { echo "skipped=same\n"; exit(0); }
}
Setting::put('apprise_endpoint', Crypt::encryptString($ep));
if (! empty($in['urls'])) {
    Setting::put('apprise_delivery_mode', 'urls');
    Setting::put('apprise_urls', Crypt::encryptString(json_encode(array_values($in['urls']))));
} else {
    Setting::put('apprise_delivery_mode', 'config');
    Setting::put('apprise_config_key', Crypt::encryptString((string) ($in['key'] ?? '')));
}
$suffix = fn (string $e) => str_replace(['.', '-'], '_', $e);
$names = array_keys(App\Services\AppriseNotifications::EVENTS);
$anyOn = false;
foreach ($names as $e) { $anyOn = $anyOn || Setting::get('apprise_event_'.$suffix($e), '0') === '1'; }
if (! $anyOn) {
    $events = $in['events'] ?? ['device.offline', 'device.online', 'device.pending_approval', 'console.login_failed', 'security.alarm'];
    foreach ($names as $e) { Setting::put('apprise_event_'.$suffix($e), in_array($e, $events, true) ? '1' : '0'); }
}
Setting::put('apprise_enabled', '1');
$d = app(App\Services\AppriseNotifications::class)->test();
echo "configured=".(app(App\Services\AppriseNotifications::class)->isConfigured() ? 'yes' : 'no')." test_delivery=".$d->status.($d->error ? " ({$d->error})" : '')."\n";
