<?php
require __DIR__ . '/HttpFixture.php';
// Simulate the child after a failed extension retry. Disable passthru so a regression
// fails immediately rather than launching an unbounded descendant process chain.
$process=proc_open([PHP_BINARY, '-n', '-d', 'disable_functions=passthru',
    __DIR__.'/AccountTransactionTest.php', '--sqlite-retry'],
    [1=>['pipe','w'],2=>['pipe','w']],$pipes);
expect(is_resource($process), 'Cannot launch SQLite retry fixture');
$output=stream_get_contents($pipes[1]).stream_get_contents($pipes[2]);
foreach($pipes as $pipe) fclose($pipe);
$status=proc_close($process);
expect($status===1 && str_contains($output, 'SQLite unavailable after one extension retry'), 'Unavailable SQLite did not fail clearly after one retry');
expect(!str_contains($output, 'passthru'), 'Unavailable SQLite tried to spawn another child');
echo "PASS SqliteRetryTest (unavailable extension stops after one retry)\n";
