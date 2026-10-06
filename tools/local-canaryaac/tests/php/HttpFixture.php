<?php
// Disposable HTTP fixture; never loads the real dotenv or connects to a database.
final class HttpFixture
{
    public string $root;
    private $process;
    private int $port;

    public function __construct()
    {
        $this->root = sys_get_temp_dir() . '/canaryaac-security-' . bin2hex(random_bytes(8));
        mkdir($this->root, 0700, true);
    }

    public function write(string $path, string $content): void
    {
        $target = $this->root . '/' . $path;
        if (!is_dir(dirname($target))) mkdir(dirname($target), 0700, true);
        file_put_contents($target, $content);
    }

    public function start(string $router): void
    {
        $socket = stream_socket_server('tcp://127.0.0.1:0', $error, $message);
        if (!$socket) throw new RuntimeException('Cannot allocate loopback fixture port');
        $this->port = (int) substr(strrchr(stream_socket_get_name($socket, false), ':'), 1);
        fclose($socket);
        $this->process = proc_open([PHP_BINARY, '-d', 'display_errors=0', '-S', '127.0.0.1:' . $this->port,
            '-t', $this->root, $router], [0 => ['pipe', 'r'], 1 => ['file', $this->root . '/server.log', 'a'],
            2 => ['file', $this->root . '/server.log', 'a']], $pipes, $this->root);
        if (!is_resource($this->process)) throw new RuntimeException('Cannot start fixture');
        fclose($pipes[0]);
        for ($i = 0; $i < 100; ++$i) {
            $connection = @fsockopen('127.0.0.1', $this->port, $error, $message, 0.05);
            if ($connection) { fclose($connection); return; }
            usleep(20000);
        }
        throw new RuntimeException('Fixture did not start');
    }

    public function request(string $path, string $method = 'GET', string $body = '', array $headers = []): array
    {
        $socket = fsockopen('127.0.0.1', $this->port);
        stream_set_timeout($socket, 5);
        $request = "$method $path HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n";
        foreach ($headers as $name => $value) $request .= "$name: $value\r\n";
        if ($method === 'POST') $request .= "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: " . strlen($body) . "\r\n";
        fwrite($socket, $request . "\r\n" . $body);
        $raw = stream_get_contents($socket);
        fclose($socket);
        [$headerText, $content] = array_pad(explode("\r\n\r\n", $raw, 2), 2, '');
        preg_match('/^HTTP\/1\.[01] (\d+)/', $headerText, $matches);
        $parsed = [];
        foreach (explode("\r\n", $headerText) as $line) {
            if (str_contains($line, ':')) {
                [$name, $value] = explode(':', $line, 2);
                $parsed[strtolower($name)][] = trim($value);
            }
        }
        return ['status' => (int) ($matches[1] ?? 0), 'headers' => $parsed, 'body' => $content];
    }

    public function close(): void
    {
        if (is_resource($this->process)) { proc_terminate($this->process); proc_close($this->process); }
        // The root is unique and was created by this fixture. Never follow directory links.
        $remove = function (string $path) use (&$remove): void {
            $resolved = realpath($path);
            $link = is_link($path) || ($resolved !== false && strtolower(str_replace('\\', '/', $resolved)) !== strtolower(str_replace('\\', '/', $path)));
            if ($link) {
                if (!@unlink($path)) rmdir($path);
            } elseif (is_dir($path)) {
                foreach (scandir($path) as $name) if ($name !== '.' && $name !== '..') $remove($path . '/' . $name);
                rmdir($path);
            } else { unlink($path); }
        };
        $remove($this->root);
    }
}

function expect(bool $condition, string $message): void
{
    if (!$condition) throw new RuntimeException($message);
}
