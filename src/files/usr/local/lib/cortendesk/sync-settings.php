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
foreach ($in as $key => $value) {
    if (! in_array($key, $allowed, true) || ! is_string($value)) { continue; }
    if (App\Models\Setting::query()->find($key) !== null) {
        App\Models\Setting::put($key, $key === 'rdgen_url' ? rtrim($value, '/') : trim($value));
        echo "updated setting $key\n";
    }
}
