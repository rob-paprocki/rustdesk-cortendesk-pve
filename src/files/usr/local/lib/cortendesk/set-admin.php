<?php
// set-admin.php -- create or update a CortenDesk administrator. Run as the app user (cortendesk) from /opt/cortendesk.
// stdin (never argv/env), one value per line:  username, password, [email], [previous username]
// With a previous username that exists (and the new name is free), that account is renamed instead of
// adding a second admin. Updating an existing account revokes all its access (sessions, remember-me,
// trusted browsers, RustDesk-client tokens).
// Exit 2 on validation errors.
$base = getenv('CORTENDESK_DIR') ?: '/opt/cortendesk';
chdir($base);
require $base.'/vendor/autoload.php';
$app = require $base.'/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

$user  = trim((string) fgets(STDIN));
$pass  = rtrim((string) fgets(STDIN), "\r\n");
$email = trim((string) fgets(STDIN));
$prev  = trim((string) fgets(STDIN));
if (! preg_match('/^[A-Za-z0-9._@-]{3,64}$/', $user)) { fwrite(STDERR, "username must be 3-64 chars of A-Z a-z 0-9 . _ @ -\n"); exit(2); }
if (mb_strlen($pass) < 8) { fwrite(STDERR, "password must be at least 8 characters\n"); exit(2); }
if ($email !== '' && ! filter_var($email, FILTER_VALIDATE_EMAIL)) { fwrite(STDERR, "invalid email\n"); exit(2); }

$u = App\Models\User::where('username', $user)->first();
if ($u === null && $prev !== '' && $prev !== $user) {
    $u = App\Models\User::where('username', $prev)->first();
    if ($u !== null) { $u->username = $user; }
}
$created = $u === null;
$u ??= new App\Models\User(['username' => $user, 'name' => 'Administrator']);
$u->password  = $pass;   // 'hashed' cast -> bcrypt
$u->is_admin  = true;
$u->is_active = true;
if ($email !== '') { $u->email = $email; }
$u->save();
if (! $created) {
    $u->revokeAllAccess();
}
echo ($created ? 'created' : 'updated')." admin '{$user}'\n";
