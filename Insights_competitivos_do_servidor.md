# Insights competitivos para o servidor

**Data da análise:** 5 de outubro de 2026

**Posicionamento recomendado:** Modern Global Custom, high-rate controlado, Retro PvP

**Documento de origem:** [Analise_para_insights.md](Analise_para_insights.md)

## 1. Resumo executivo

Este servidor já possui base técnica e conteúdo suficientes para se diferenciar. Ele não é apenas um Canary padrão: a branch atual combina cliente 15.25, mapa Global, Task Board com atividades diárias e semanais, Weapon Proficiency, multiprotocolo, livestream, arena, sistemas modernos de Tibia e conteúdo customizado de nível alto.

O principal risco não é a falta de funcionalidades. É lançar um conjunto extenso de sistemas sem uma jornada clara, uma economia medida e uma operação preparada. Hoje há sinais de um produto ainda local/em preparação: identidade genérica, credenciais padrão, SHA-1 para senhas, métricas e backup interno desativados, URLs locais, bugs conhecidos e conteúdo customizado sem uma origem de aquisição encontrada no repositório.

As prioridades recomendadas são, nesta ordem:

1. preparar segurança, backup, observabilidade e processo de release;
2. fechar os fluxos dos itens customizados e corrigir defeitos visíveis;
3. medir a economia e simular a curva de progressão antes de rebalanceá-la;
4. transformar os sistemas existentes em uma jornada do nível 1 ao 1000+;
5. fortalecer guilds, temporadas e monetização somente depois de validar retenção e equilíbrio.

**Conclusão central:** o projeto deve competir por coerência, confiabilidade e progressão com escolhas, não por quantidade de features.

---

## 2. Escopo e método

Esta é uma auditoria estática do repositório e da configuração local. Foram observados:

- código, datapacks, documentação e testes presentes na branch;
- diferenças locais em relação ao Git;
- configuração atual em `config.lua` e estágios em `data/stages.lua`;
- integrações dos novos itens, proficiências e montaria;
- documentação operacional incluída no próprio Canary;
- o diagnóstico de mercado de `Analise_para_insights.md`;
- fontes externas consultadas em 5 de outubro de 2026.

Esta análise **não comprova** disponibilidade real, ausência de exploits, balanceamento em produção ou funcionamento de todas as quests. Não foram fornecidos dados de jogadores, economia, logs de produção, website, loja externa ou sessões reais. Onde não há evidência suficiente, o documento usa “não verificado” em vez de presumir que algo funciona.

Os números de concorrentes são fotografias de um momento e podem incluir métodos diferentes de contagem. Eles são úteis para confirmar a diversidade do mercado, não para provar causalidade nem para definir metas de jogadores online.

---

## 3. Estado atual do servidor

### 3.1. Identidade técnica confirmada

| Área | Estado observado | Leitura estratégica |
| --- | --- | --- |
| Base | Canary descrito pelo Git como `v3.6.0-104`, com metadado antigo `1.4.1` no `package.json` | A versão do produto deve ter uma única fonte de verdade |
| Cliente principal | Protocolo 15.25 | Bom alinhamento com Modern Global |
| Datapack | `data-otservbr-global`, mapa `otservbr` | Grande volume de conteúdo familiar |
| PvP | `worldType = "retro-pvp"` | Posicionamento compreensível; exige balanceamento próprio |
| Progressão | XP por estágios, skills e magic level acelerados | Apropriado para high-rate, mas a cauda atual ameaça a longevidade |
| Conveniência | Autoloot, autobank, viagens gratuitas e offline training | Reduz atrito, de acordo com o diagnóstico de mercado |
| Operação atual | IP, nome, URL da loja e identidade ainda locais/genéricos | Não está pronto para aquisição pública |

Há uma inconsistência de versão a resolver: o código anuncia protocolo 15.25, o Git descreve uma revisão posterior ao tag `v3.6.0`, enquanto `package.json` ainda informa `1.4.1`. Isso não quebra necessariamente o jogo, mas prejudica suporte, atualizações, comunicação de incidentes e reprodução de builds.

### 3.2. Conteúdo e sistemas já disponíveis

A inspeção estática encontrou aproximadamente 1.656 arquivos de monstros, 1.036 NPCs e 978 scripts de quests no datapack Global. Quantidade não equivale a qualidade, mas confirma que não há necessidade de construir um mundo do zero.

Capacidades relevantes já presentes:

- Task Board habilitado, com Bounty, tarefas semanais, preferências, rerolls, melhorias de talismã, recompensas e pontos adicionais da Wheel;
- Daily Reward, Hunting Tasks, Bestiary, Charms, Bosstiary, Prey, Imbuements, Forge, Gem Atelier, Hazard, Wheel e Market;
- autoloot, autobank, offline training, reward chest e Game Store;
- arenas 2x2 e 10x10 e persistência de guild wars;
- livestream/cast;
- multiprotocolo e suporte técnico a Expert PvP, embora o mundo atual use Retro PvP;
- Weapon Proficiency com 443 registros no arquivo atual;
- testes dedicados e documentação extensa para o Task Board.

Isso muda a decisão de produto. Em vez de adicionar outro sistema diário, deve-se conectar Task Board, quests, bosses, proficiency, economia e PvP a uma mesma sequência de objetivos.

### 3.3. Personalização própria em andamento

As alterações locais incluem:

- 29 novos registros em `items.xml`, principalmente equipamentos Moonsilver e Stellar Moonsilver;
- armas de nível 1000 e capacetes de nível 800;
- 23 novas entradas de Weapon Proficiency relacionadas aos itens Moonsilver e à snowball;
- montaria Radiant Nimbus e o item `cloud in a bottle`;
- atualização de `appearances.dat`;
- custom loot atualmente limitado a uma pequena adição no Dragon; o loot global de exemplo foi corretamente desativado.

O ponto fraco é o ciclo de aquisição. A busca estática não encontrou Moonsilver, `cloud in a bottle` ou Radiant Nimbus em drops, quests, crafting, NPCs ou ofertas fora dos arquivos de definição e uso. Isso pode significar que a entrega ocorre em um sistema externo não incluído, mas, no repositório analisado, os itens parecem **definidos sem uma fonte jogável**.

Também não foram encontrados testes específicos para os IDs customizados, suas proficiências ou a montaria. Como o protocolo possui diferenças até entre builds 15.25, cada ativo novo deve ser validado com a build exata do cliente distribuído.

### 3.4. Progressão atual

Curva de experiência configurada:

| Faixa | Multiplicador |
| --- | ---: |
| 1–90 | 100x |
| 91–200 | 80x |
| 201–500 | 60x |
| 501–1000 | 40x |
| 1001+ | 40x |

O início rápido está alinhado à proposta. O problema é a ausência de desaceleração depois do nível 501. O mesmo multiplicador de 40x continua após 1000, justamente quando aparecem os novos equipamentos de maior valor.

Além disso, ataque, cooldown, regeneração, skills e magic level foram acelerados simultaneamente. Mesmo que cada ajuste isolado pareça conveniente, a combinação altera:

- tempo para matar e tempo para morrer no PvP;
- consumo de poções e outros sumidouros de gold;
- XP e loot por hora;
- diferença prática entre vocações;
- valor do equipamento e da proficiency;
- duração real de bosses e quests.

Não se recomenda escolher novos multiplicadores apenas por intuição. Primeiro deve ser criado um simulador ou teste repetível de XP/h, dano sustentado, cura, gasto e loot por vocação em faixas representativas.

### 3.5. Retenção

O Task Board já cobre boa parte do que seria buscado com um sistema novo de missões diárias e semanais. Ele é hoje o melhor candidato a “espinha dorsal” da retenção, porque já possui:

- conteúdo diário e semanal;
- dificuldades por faixa de nível;
- rerolls e preferências;
- progressão de melhorias;
- loja e moedas próprias;
- integração com monstros, loot, Bestiary e Wheel;
- cobertura de testes muito superior à personalização recente.

Dois cuidados são importantes:

1. a oferta padrão da loja do Task Board converte pontos em crystal coin, criando uma fonte direta de gold;
2. os níveis máximos de melhoria e preços precisam ser avaliados com telemetria real, pois podem virar grind excessivo ou inflação de poder.

Antes de criar Battle Pass, o servidor deve provar que o loop Task Board → caça → upgrade → boss/PvP → recompensa é divertido e economicamente sustentável.

### 3.6. Economia e monetização

O repositório oferece muitas fontes potenciais de valor: loot, tasks, bosses, reward chest, daily rewards, Store, Forge e Market. Porém, não há no escopo analisado um painel que demonstre o equilíbrio entre entradas e saídas.

Riscos confirmados ou prováveis:

- XP alto aumenta loot/hora mesmo com `rateLoot = 1`;
- autobank torna a entrada de moeda mais fluida e menos perceptível;
- viagens gratuitas eliminam um sumidouro tradicional;
- crystal coins no Task Board transformam atividade recorrente em gold;
- regeneração e combate acelerados mudam o consumo de suprimentos;
- a Game Store contém categorias de boosts, consumíveis e exercise weapons, que exigem uma política explícita contra pay-to-win;
- novos itens endgame ainda não possuem custo de obtenção visível, impedindo avaliar raridade e impacto.

O servidor precisa de um “livro razão” da economia: quanto entra, quanto sai, de onde vem e quem concentra. Sem isso, qualquer novo tier ou moeda apenas esconde inflação.

### 3.7. Operação, segurança e qualidade

Bloqueadores para produção encontrados na configuração local:

- `passwordType = "sha1"`;
- usuário e senha de banco `canary/canary`;
- backup interno do banco desativado;
- Prometheus e saída de métricas desativados;
- nome, MOTD, proprietário e URL ainda apontando para valores genéricos;
- imagens da Store apontando para `127.0.0.1`;
- `maxPlayers = 0`, sem limite de capacidade explicitamente testado;
- suporte a protocolos antigos habilitado, aumentando a matriz de compatibilidade;
- dois defeitos de mensagens de avanço registrados em `Erros_Para_Corrigir.md`;
- arquivos `.bak` grandes versionados dentro da árvore de dados;
- commit local amplo com mensagem `OK`, o que dificulta auditoria e rollback.

O repositório já contém suporte a Prometheus/Grafana e documentação de backup. Portanto, a lacuna é principalmente de ativação, configuração segura e disciplina operacional.

SHA-1 não é apropriado para novas senhas. A OWASP recomenda algoritmos adaptativos e resistentes a memória, preferindo Argon2id. A migração deve preservar contas antigas por rehash gradual no login ou por um processo compatível com o stack de autenticação; não se deve simplesmente trocar o campo e invalidar usuários.

---

## 4. Posicionamento competitivo recomendado

### Proposta

> **Um Modern Global Custom de progressão rápida no início, builds profundas no endgame e competição Retro PvP duradoura, sem resets destrutivos.**

### Promessa ao jogador

- entrar e chegar rapidamente ao conteúdo divertido;
- sempre enxergar o próximo objetivo;
- evoluir por level, equipamento, proficiency e escolhas, não apenas por dano bruto;
- competir sem precisar comprar poder;
- encontrar conteúdo individual, em party e em guild;
- confiar que o progresso continuará existindo no longo prazo.

### O que torna o servidor diferente

O diferencial não deve ser “tem Canary + Global”. Isso é replicável. A combinação defensável é:

1. Task Board profundamente integrado ao mundo;
2. linha Moonsilver como progressão customizada obtida jogando;
3. Weapon Proficiency como especialização de build;
4. PvP com regras claras e temporadas sem apagar personagens;
5. estabilidade e transparência operacional como parte da marca.

### Decisões de foco

- Manter um único mundo principal no lançamento para não dividir a população.
- Manter Retro PvP até que testes provem uma razão forte para migrar para Expert PvP.
- Não prometer “no reset” antes de existir backup restaurável, política de rollback e economia sustentável.
- Não lançar Battle Pass antes de validar o Task Board.
- Não usar level infinito como conteúdo; após 1000, priorizar progressão horizontal e prestígio.

---

## 5. Jornada recomendada

| Etapa | Objetivo do jogador | Sistemas principais | Saída esperada |
| --- | --- | --- | --- |
| 1–60 | Aprender e escolher vocação | tutorial curto, quests guiadas, autoloot | primeira build funcional |
| 60–200 | Descobrir o mundo | quests Global, Task Board beginner/adept, party | rotina de caça compreendida |
| 200–400 | Criar identidade | bosses, imbuements, prey, charms, arena casual | primeira especialização |
| 400–800 | Cooperar e otimizar | Task Board master, forge, guild, raids | build consolidada |
| 800–1000 | Preparar endgame custom | cadeia Moonsilver, proficiency, bosses próprios | acesso ao tier customizado |
| 1000+ | Competir e colecionar | temporadas, rankings, guild objectives, variantes Stellar | prestígio e opções, não poder ilimitado |

Cada transição precisa aparecer no jogo por uma interface, NPC, quest log ou mensagem clara. O jogador não deve depender de Discord ou wiki para descobrir o objetivo seguinte.

---

## 6. Roadmap priorizado

### Fase 0 — Prontidão para produção (0–4 semanas)

#### P0.1. Segurança e identidade

- Migrar autenticação de SHA-1 para Argon2id com estratégia compatível para contas existentes.
- Remover credenciais padrão e carregar segredos por ambiente.
- Definir domínio, nome, MOTD, proprietário, suporte e URLs públicas.
- Publicar regras de PvP, política de punição, privacidade e política de reembolso.
- Auditar a necessidade real de cada protocolo antigo antes de expor portas públicas.

**Gate:** nenhuma credencial padrão, nenhum segredo versionado, fluxo de criação/login/recuperação testado e rate limiting verificado.

#### P0.2. Operação confiável

- Habilitar Prometheus e construir um dashboard mínimo.
- Medir disponibilidade, jogadores, login, latência do dispatcher, Lua, SQL, saves e crashes.
- Automatizar backups e realizar restauração completa em ambiente isolado.
- Criar staging compatível com produção e checklist de release/rollback.
- Fixar versões de imagens e dependências em produção; evitar `latest` como política de release.

**Gate:** restauração cronometrada e documentada, alerta de indisponibilidade funcionando e rollback ensaiado.

#### P0.3. Fechar conteúdo em andamento

- Criar a cadeia de aquisição Moonsilver e Radiant Nimbus: fonte, requisito, custo, chance, proteção contra duplicação e sink.
- Sincronizar servidor e cliente para a build exata, inclusive qualquer catálogo exigido pelo cliente distribuído.
- Criar smoke tests para todos os novos IDs, vocações, slots, augments e proficiências.
- Corrigir os dois defeitos conhecidos de mensagens de skill/Bosstiary.
- Remover backups binários/XML da árvore versionada após garantir cópia recuperável fora dela.

**Gate:** todo item customizado pode ser obtido legitimamente, usado pelo cliente e rastreado até sua origem.

### Fase 1 — Balanceamento baseado em dados (4–8 semanas)

#### P1.1. Instrumentação de gameplay

Registrar de forma agregada, sem alta cardinalidade desnecessária:

- XP, gold, loot e gasto por hora/faixa/vocação;
- duração e sucesso de bosses;
- dano, cura, mortes e participação em PvP;
- criação, upgrade, trade e destruição de itens;
- escolha e conclusão de tarefas;
- uso de proficiency, forge, imbuements e consumíveis.

#### P1.2. Laboratório de balanceamento

Criar cenários reproduzíveis para níveis 60, 200, 400, 800, 1000 e 1000+ com equipamentos de entrada, medianos e ótimos. Comparar todas as vocações em:

- alvo único, área e sustain;
- XP/h, lucro/h e custo/h;
- time-to-kill e sobrevivência;
- solo, party e PvP.

Só depois alterar stages, ataque, cooldown, regeneração ou equipamentos.

#### P1.3. Redesenho da curva

A direção sugerida é manter o início rápido e criar mais degraus de desaceleração entre 500 e 1000, com uma queda adicional após 1000. Os multiplicadores finais devem ser definidos pela meta de tempo, não pela aparência do número.

Metas de design a decidir e medir:

- tempo mediano até 60, 200, 400, 800 e 1000;
- tempo até a primeira task, boss, imbuement e peça Moonsilver;
- distância recuperável entre novato ativo e veterano;
- poder marginal obtido após 1000.

### Fase 2 — Jornada e economia (8–12 semanas)

#### P2.1. Integrar os sistemas existentes

- Fazer o onboarding apresentar Task Board e autoloot.
- Usar Task Board para apontar hunts adequadas sem substituir escolha.
- Fazer quests e bosses fornecerem materiais para a linha Moonsilver.
- Fazer proficiency abrir estilos de build, não bônus obrigatórios universais.
- Conectar arenas e guild wars a rankings sazonais cosméticos.

#### P2.2. Controlar a economia

- Criar painel semanal de faucets e sinks por moeda.
- Acompanhar uma cesta fixa de itens para medir inflação.
- Limitar recompensas líquidas de gold até conhecer o impacto do Task Board.
- Usar crafting, reparo/serviços, reroll e progressão de guild como sinks previsíveis.
- Preferir materiais vinculados à atividade a adicionar moedas sem finalidade clara.
- Definir política de bind/trade para Moonsilver antes do lançamento.

#### P2.3. Monetização justa

Priorizar:

- outfits, mounts e decoração;
- conveniência sem poder de combate;
- nome, sexo e serviços de conta com regras transparentes;
- premium com valor claro, sem bloquear o núcleo competitivo.

Evitar vender:

- equipamento Moonsilver/Stellar;
- níveis ou XP de proficiency relevantes;
- bônus exclusivos de dano, defesa ou cooldown;
- acesso pago exclusivo às melhores hunts;
- rerolls ilimitados que convertam dinheiro em progressão dominante.

O catálogo atual de boosts, consumíveis e exercise weapons precisa de uma revisão item a item antes de ser publicado.

### Fase 3 — Social e live operations (12–20 semanas)

- Guild tasks semanais com contribuição individual limitada.
- Um boss de guild com dificuldade escalável, sem exigir guild gigante.
- Ranking sazonal individual e de guild separado por modalidade.
- Temporadas de 8–12 semanas sem reset de personagem, recompensando cosméticos, títulos e troféus.
- Catch-up controlado para novos jogadores, sem entregar o mesmo prestígio do veterano.
- Calendário previsível de eventos, patches e manutenção.
- Website/launcher com status, changelog, guia de início, rankings auditáveis e suporte.

Somente após duas temporadas saudáveis deve ser considerado um Battle Pass. Se criado, deve organizar objetivos e cosméticos; não deve ser a principal fonte de poder.

---

## 7. Métricas que devem governar decisões

### Produto e retenção

- conversão de conta criada → primeiro login → primeira hunt → primeira task;
- retenção D1, D7 e D30 por coorte;
- tempo de sessão e frequência semanal;
- tempo até primeira party e primeira guild;
- porcentagem que chega a 60, 200, 400, 800 e 1000;
- Task Board: seleção, reroll, conclusão e abandono por dificuldade.

### Progressão e equilíbrio

- XP/h, lucro/h, dano e cura por vocação e faixa;
- mortes PvE/PvP e causa;
- participação e vitória em arena/guild war;
- distribuição de equipamentos e proficiências;
- diferença de poder entre percentis, não apenas entre top 1 e média.

### Economia

- gold criado e removido por dia;
- saldo líquido por personagem ativo;
- concentração de riqueza;
- preço e volume de uma cesta fixa de itens;
- materiais Moonsilver criados, usados, negociados e destruídos;
- participação da Store versus obtenção jogando.

### Confiabilidade

- disponibilidade e jogadores afetados por incidente;
- login bem-sucedido e latência de login;
- latência p50/p95/p99 do loop principal, Lua e SQL;
- crashes, saves e duração de shutdown/startup;
- idade do último backup válido e tempo de restauração;
- erro por versão/build do cliente.

Antes de impor metas absolutas de retenção ou economia, registrar uma baseline com jogadores reais. Para confiabilidade, adotar inicialmente um SLO público compatível com a capacidade operacional e aumentá-lo apenas após comprová-lo por alguns ciclos.

---

## 8. Definition of Done para qualquer nova feature

Uma feature só deve ser considerada pronta quando tiver:

1. objetivo de comportamento do jogador claramente definido;
2. fonte e sink econômico documentados;
3. compatibilidade com as builds de cliente suportadas;
4. caminho de obtenção e recuperação de falhas;
5. telemetria agregada;
6. testes automatizados proporcionais ao risco;
7. teste de abuso, duplicação, concorrência e reconexão;
8. documentação para jogador e suporte;
9. plano de rollback;
10. responsável e indicador de sucesso após o lançamento.

Para itens e mounts customizados, a validação deve cobrir ainda `items.xml`, `appearances.dat`, catálogos do cliente quando aplicáveis, scripts de uso/aquisição, achievements e proficiency.

---

## 9. O que não fazer agora

- Não criar um segundo mundo antes de preencher o primeiro.
- Não lançar Battle Pass para compensar falta de jornada.
- Não adicionar mais tiers acima de Stellar antes de medir o tier atual.
- Não aumentar novamente XP, ataque ou regeneração para “deixar mais divertido” sem teste de economia e PvP.
- Não ativar Expert PvP apenas porque o código suporta a opção.
- Não usar quantidade de quests como prova de que elas funcionam.
- Não prometer no-reset sem restauração testada e mecanismos contra inflação.
- Não vender poder para financiar o lançamento; isso destrói a credibilidade competitiva difícil de recuperar depois.
- Não copiar concorrentes feature por feature. O mercado mostra que modelos muito diferentes podem funcionar quando a proposta é clara e a operação é estável.

---

## 10. Sequência objetiva de decisão

```text
Segurança e backup
        ↓
Observabilidade e baseline
        ↓
Integração completa do conteúdo customizado
        ↓
Balanceamento de progressão e combate
        ↓
Economia sustentável
        ↓
Jornada 1–1000+
        ↓
Guilds e temporadas
        ↓
Monetização e aquisição em escala
```

Se uma etapa não puder ser medida ou recuperada, a próxima deve esperar. Essa disciplina é mais competitiva do que lançar muitas funcionalidades simultâneas.

---

## 11. Fontes e evidências principais

### Repositório local

- [Configuração atual](config.lua)
- [Estágios de progressão](data/stages.lua)
- [Definições de itens](data/items/items.xml)
- [Weapon Proficiency](data/items/proficiencies.json)
- [Custom monster loot](data/scripts/systems/custom_monster_loot.lua)
- [Configuração do Task Board](data/modules/scripts/taskboard/settings.lua)
- [Contrato do Task Board](docs/systems/taskboard-module.md)
- [Compatibilidade do cliente 15.25](docs/systems/client-15-25-compatibility-update.md)
- [Operação do Canary](docs/operations.md)
- [Problemas conhecidos](Erros_Para_Corrigir.md)

### Fontes externas

- [OTServList — ranking e snapshot do mercado](https://otservlist.net/): confirma, no snapshot consultado, a coexistência de Modern Global, Retro e diferentes taxas de XP entre servidores populosos.
- [Estatísticas do OTServList](https://www.otservlist.org/statistics): reforça que distribuição do servidor ou taxa de XP isolada não explica a população.
- [Repositórios oficiais OpenTibiaBR](https://github.com/orgs/opentibiabr/repositories): contexto do ecossistema Canary, cliente e login-server.
- [Wiki do Canary — funcionalidades](https://github.com/opentibiabr/canary/wiki/Informations): inventário de capacidades oferecidas pela base.
- [OWASP Password Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html): recomendação de Argon2id e rejeição de hashes rápidos para novas senhas.
- [Google SRE — Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/): uso de monitoramento para tendências, alertas, diagnóstico e sinais de tráfego, erros, latência e saturação.

---

## 12. Conclusão

O servidor está mais próximo de um produto competitivo do que a configuração local faz parecer. Os ativos difíceis já existem: engine moderna, datapack amplo, sistemas de progressão, cliente atual, Task Board robusto e uma direção de conteúdo próprio.

O salto competitivo virá de reduzir incoerências:

- transformar conteúdo definido em conteúdo obtível;
- transformar XP alto em uma curva com começo, meio e endgame;
- transformar sistemas independentes em uma jornada;
- transformar logs e métricas disponíveis em decisões;
- transformar configuração local em operação segura;
- transformar monetização em confiança, não vantagem comprada.

Se essas bases forem concluídas antes de expandir o escopo, o projeto pode ocupar um espaço claro: familiar o suficiente para atrair jogadores de Global, customizado o suficiente para criar identidade e estável o suficiente para sustentar uma comunidade no longo prazo.
