---
name: add-canary-creature
description: Use when adding a custom monster or creature to this Canary/OTServBR project with a modern Tibia appearance, OTS Creator assets, Bestiary data, or a GM spawn test.
---

# Adicionar criatura ao Canary

Use este fluxo para uma criatura nova ser visualmente válida no cliente moderno e reconhecida pelo servidor. Preserve o escopo pedido: se o usuário solicitou apenas `/m`, não crie spawn, loot, quest ou mapa.

## Antes de alterar

- Confirme a referência de gameplay, a classe Bestiary, o nome e o escopo de spawn.
- Ache um `lookType` de outfit livre na aparência compilada e um `raceId` positivo livre entre todos os `data-otservbr-global/monster/**/*.lua`. Nunca derive um ID livre pela proximidade de outra criatura.
- Para arte 64 px, obtenha quatro direções — norte/costas, leste/direita, sul/frente e oeste/esquerda — e o número de fases de caminhada.

## Implementação

1. Crie `data-otservbr-global/monster/<categoria>/<nome>.lua`, partindo do monstro de referência. Altere somente os campos necessários, incluindo `outfit.lookType`, `raceId` e a classe Bestiary. Mantenha atributos e combate do modelo quando o pedido for “mesmas características”.
2. Use o cliente efetivo em `.tools/otclient-redemption/data/things/1525`. Para importar pelo OTS Creator, prepare um `.otobj` com `manifest.json`, `sprites/idle.png` e `sprites/walking.png`. Leia [assets modernos](references/modern-client-assets.md) antes de empacotar ou depurar uma aparência.
3. Atualize o catálogo e copie para `data/items/appearances.dat` exatamente o `appearances-*.dat` selecionado pelo `catalog-content.json` do cliente. Não suponha que o `.dat` mais recente no diretório seja o ativo.
4. Acrescente ou amplie uma verificação de regressão para o monstro: IDs únicos, aparência do servidor igual à ativa no cliente e pixels visíveis em cada frame compilado. Em CI sem `.tools`, a checagem de asset pode pular; localmente ela deve falhar se o asset esperado não existir.

## Portões de validação

| Verificação | Evidência exigida |
| --- | --- |
| Direções e animação | Cada fase é empacotada N, E, S, W; o preview mostra as quatro direções. |
| Asset real | Todo sprite novo do `.bmp.lzma` possui pixels não transparentes; hash, catálogo ou tamanho do arquivo não bastam. |
| Servidor/cliente | `appearances.dat` ativo e `data/items/appearances.dat` são byte a byte iguais. |
| Jogo | Reinicie o cliente para recarregar assets; teste `/m Nome`, giro, caminhada e Bestiary. Reinicie o servidor apenas quando autorizado ou necessário. |

## Diagnóstico rápido

Se o monstro tem nome e vida mas está invisível, trate como falha de asset do cliente, não de Lua: decodifique a folha indicada pelo catálogo e conte pixels visíveis para cada ID novo. Um `.otobj` importado pode produzir uma folha magenta/transparente mesmo com catálogo e `appearances.dat` coerentes. Reimporte ou repare a folha, valide os frames novamente e só então reinicie o cliente.

Não declare sucesso por uma definição Lua válida ou por um preview isolado: o gate é a sprite compilada não transparente e o spawn no cliente recarregado.
