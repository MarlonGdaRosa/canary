# CanaryAAC: preparação verificável para produção

## Escopo autorizado

O site já responde em http://127.0.0.1:8080 e cria personagens. A solicitação de 2026-10-06 autoriza concluir a integração e preparar sua futura publicação. A entrega contém código reproduzível, proteção dos fluxos habilitados, configuração de implantação e verificações que distinguem preparação local de lançamento público. DNS, certificados reais, portas públicas, alteração de contas existentes e cadastro no otservlist permanecem para a implantação posterior.

O worktree existente `codex/canaryaac-local-integration` continua sendo usado. Alterações de gameplay do usuário ficam preservadas. O aplicativo ativo está em `.tools/canaryaac`; o upstream está fixado em `d9333dcf33d3f55cee476e9ee8ebfe3f28113c19`. Alterações locais do aplicativo serão capturadas em patches ordenados, excluindo `.env`, vendor, caches e segredos. Os requisitos de cadastro e preservação do design local continuam válidos. Este plano substitui as tarefas ainda não executadas 4–8 do plano local, agrupando suas entregas com as proteções de publicação agora solicitadas; o fix pendente da tarefa 3 continua sendo revisado separadamente.

## Evidências de entrada

HEAD em caminhos sensíveis retornou 200: `.env`, `.git/HEAD`, `composer.lock`, `canaryaac.sql` e `vendor/composer/installed.json`. Nenhum corpo secreto foi lido. O router permite qualquer arquivo existente dentro do checkout. O cadastro usa SHA-1, transforma a senha antes de gravá-la e realiza inserts separados. Existem mudanças locais úteis de apresentação e compatibilidade, que precisam ser preservadas. A revisão anterior da migração deixou pendente o uso de fonte apropriada para os grants globais de PUBLIC/roles no MariaDB 11.8.5.

## Arquitetura e proteção

1. Router local e entrada pública com a mesma política: somente arquivos estáticos de extensões e diretórios permitidos, com contenção de realpath; arquivos internos, ocultos, backups e PHP arbitrário retornam 404. Fallbacks de imagens existentes continuam funcionando. A entrada pública vive em `public/index.php`; o docroot de produção é `public`, não a raiz do aplicativo.
2. Uma classe pequena de segurança controla sessão, CSRF e limites de tentativas. Cookies são HttpOnly e SameSite=Lax, usam Secure em produção HTTPS, sessão estrita e regeneração após login. Todos os POSTs habilitados exigem token CSRF; cadastro e login têm limites persistentes por REMOTE_ADDR com locks e falham de forma segura se o estado não puder ser escrito. Cabeçalhos fornecidos pelo cliente não definem a identidade IP.
3. Perfil `APP_ENV=production` valida URL HTTPS/domínio, desliga debug, limita rotas aos fluxos revisados, desabilita administração, pagamentos, recuperação, uploads e APIs não revisadas. A implantação aponta o endpoint de cliente `/login` para o login-server; website e login do jogo permanecem componentes distintos.
4. Cadastro usa validação autoritativa, dados de mundo/sample fixados no servidor e uma conexão PDO compartilhada com transação. Account type=1, group=1, level=8, experience=4200, town=8 e posição 32369,32241,7. Vocações 1,2,3,4,9. Senhas de 12–128 caracteres são preservadas, Argon2id 65536/2/2 em formato compacto; leitura aceita SHA-1 legado sem conversão automática nem downgrade. Erros não expõem SQL, credenciais ou hashes.
5. Dependências de pagamentos/SMTP/Discord/2FA não habilitados são removidas do grafo. As dependências restantes são atualizadas para versões compatíveis, fixadas no lockfile e sujeitas a Composer validate e audit. Falha de rede é um resultado inconclusivo que bloqueia o gate de lançamento, nunca equivale a auditoria aprovada.

Estado de sessão, limiter, logs e caches fica fora de `public`, sob `.tools` no desenvolvimento e em diretório privado do serviço na produção. O perfil local continua em loopback. Não alterar `.env` privado ou ACL para facilitar execução no sandbox.

## Implantação posterior

Templates sem segredos oferecem Nginx/PHP-FPM em Linux e IIS/FastCGI em Windows. Não usar `php -S` como backend de produção. As configurações executam somente `public/index.php`, permitem somente estáticos conhecidos, aplicam HTTPS e limitam `/login` antes de encaminhar para 127.0.0.1:8088. Não confiar indiscriminadamente em forwarded headers. Os exemplos usam `example.invalid` e endereços explicitamente não implantáveis; o preflight recusa placeholders em modo produção.

O checklist inclui segredos únicos e rotação dos padrões locais antes de publicar, permissões do banco, política de PUBLIC para canary, backup privado/off-host e restore testado, supervisão/restart, observabilidade sem corpos de requests, privacidade/regras/contato e configuração de status/jogo. Otservlist lista o servidor, não hospeda o site. Status TCP7171 e jogo TCP7172 exigem implantação e testes externos próprios. A FAQ oficial exige estatísticas honestas; a consistência entre online filtrado e recorde raw no Canary permanece um gate explícito, sem alteração C++ nesta entrega.

## Critérios verificáveis

- Home/cadastro/assets continuam respondendo; caminhos sensíveis, inclusive variantes codificadas e de caixa, devolvem 403/404 sem conteúdo.
- Fixtures demonstram validação das cinco vocações, senha intacta, Argon/legado, CSRF ausente/inválido, limite de tentativas, sessão/cookies e rollback de insert do personagem.
- Patches são aplicáveis em ordem ao upstream em fixture limpa; nenhum segredo ou vendor gerado entra neles.
- Exportação de release exclui `.env`, `.git`, dumps, logs, caches e estado; registra hashes de arquivos públicos/código e patches, nunca segredo.
- Preflight local coleta apenas evidência não sensível; preflight produção recusa HTTP, localhost, placeholders, servidor embutido, audit ausente/falha, controles desabilitados e dados de publicação faltantes.
- Operador recebe comandos precisos para validar, exportar, configurar produção, backup/restore, rollback, monitorar e preparar o cadastro no otservlist. DNS/IP/domínio e validação TLS externa continuam exigências explícitas da implantação.

## Fontes primárias

- https://www.php.net/commandline.webserver
- https://www.php.net/manual/en/install.fpm.php
- https://www.php.net/manual/en/install.windows.iis.php
- https://learn.microsoft.com/en-us/iis/configuration/system.webServer/fastCgi/
- https://otservlist.org/pages/faq

Regras numéricas atuais e formulário autenticado do otservlist precisam ser reconfirmados antes do cadastro. Código e comentários do Canary não substituem as regras oficiais.
