# Pupated Rootthing: design de integração

## Objetivo

Adicionar `Pupated Rootthing` como um monstro invocável manualmente com
`/m Pupated Rootthing`, com a folha de sprites customizada criada no projeto.
Não haverá spawns em mapas nesta entrega.

## Escopo

O monstro terá a configuração de combate do `Quara Raider`: vida, experiência,
velocidade, alvo, flags, ataques, defesas, elementos, imunidades, loot, cadáver
e vozes. Os únicos desvios de identidade serão o nome, a descrição, o look type
e a classificação Bestiary:

- `class = "Plant"`
- `race = BESTY_RACE_PLANT`
- `raceId = 2544`, verified free after the Quara IDs 2541–2543
- `Occurrence = 0` and `Locations = "Manual spawn only."`

O arquivo de definição ficará em
`data-otservbr-global/monster/plants/pupated_rootthing.lua`. A pasta já é
carregada pelo autoloader de monstros, portanto não será preciso criar registro
manual adicional.

## Aparência moderna

A fonte é a folha PNG
`artifacts/generated-sprites/pupated-rootthing-walksheet-3x4-64px.png`.
Ela contém doze frames de 64 x 64 pixels, organizados em quatro direções e três
fases de caminhada. A aparência será um outfit/criatura separado no client
moderno 15.25:

- reservar o look type `1863`, verificado livre no protobuf original; preservar
  `1841` e `1759` sem reutilizá-los;
- importar a folha como objeto 2 x 2 sprites, quatro direções, uma camada e
  três fases de animação;
- compilar os assets em
  `.tools/otclient-redemption/data/things/1525`;
- sincronizar a aparência protobuf que o servidor consulta em
  `data/items/appearances.dat`.

O look type efetivo é `1863`: o protobuf anterior à importação contém `1841`,
mas não contém `1863`. A definição Lua deve usar `1863` após a compilação.

## Dados e fluxo

1. O cliente resolve o look type novo para os sprites compilados.
2. A definição Lua retorna o mesmo look type ao criar o monstro.
3. O servidor valida esse look type no `appearances.dat` sincronizado.
4. O comando GM `/m Pupated Rootthing` encontra a nova definição e envia a
   aparência nova para o client.

Não haverá alteração de spawns, mapas, scripts de ataques ou itens nesta
entrega. Usar o cadáver e os itens de loot do Quara Raider evita criar dados de
item sem uma sprite de cadáver própria.

## Validação

- Verificar que a nova definição Lua mantém todos os campos de combate e loot
  do Quara Raider, exceto nome, descrição, look type e Bestiary.
- Verificar que o look type escolhido existe uma vez no `appearances.dat` do
  servidor e no catálogo do client.
- Iniciar o servidor e executar `/m Pupated Rootthing` como GM.
- Confirmar no client as quatro direções e as três fases de caminhada, e que
  um Quara Raider continua com o visual original.

## Falhas esperadas e prevenção

- Se o look type não estiver presente no client, o servidor pode criar o
  monstro, mas o client não o renderiza corretamente. Por isso a compilação de
  assets precede a troca na definição Lua.
- Se o `appearances.dat` do servidor e o catálogo do client divergirem, a
  sessão pode falhar ou exibir outra aparência. Eles serão gerados e validados
  como um par.
- Sem spawn configurado, reiniciar ou recarregar monstros é necessário antes
  do primeiro `/m`.
