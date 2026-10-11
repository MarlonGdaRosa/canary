# Assets modernos de criaturas

Leia esta referência ao criar ou depurar a aparência de uma criatura no OTClient Redemption. O cliente utilizado por este projeto fica em `.tools/otclient-redemption/data/things/1525`.

## OTS Creator e ordem dos frames

Para uma criatura de 64 px, use `spriteSize: 64` e `spritetype: 3`. A folha compilada é uma grade de 6 x 6 tiles, portanto mede 384 x 384 e comporta até 36 sprites.

O `.otobj` nativo é um ZIP contendo `manifest.json`, `sprites/idle.png` e `sprites/walking.png`. Defina grupos `idle` e `walking`. Para quatro direções e `P` fases, a ordem de frames de caminhada é sempre por fase:

```
fase 0: norte, leste, sul, oeste
fase 1: norte, leste, sul, oeste
...
fase P-1: norte, leste, sul, oeste
```

Para uma fonte organizada em linhas por direção e colunas por fase, o frame compilado `n` usa `direcao = n % 4` e `fase = n / 4`; recorte a fonte em `(fase * 64, direcao * 64)`. Não agrupe todas as fases de uma direção: isso faz a animação trocar de direção em vez de caminhar.

## Sincronização de aparência

`catalog-content.json` decide qual `appearances-<hash>.dat` está ativo. Copie esse arquivo — não um escolhido por data ou nome — para `data/items/appearances.dat` e compare os bytes. O registro de sprite correspondente usa `spritetype: 3` para 64 px.

## A checagem que evita criaturas invisíveis

Após a importação, decodifique a folha `.bmp.lzma` referenciada pelo catálogo e conte pixels visíveis em cada novo tile. Este é o teste de aceitação do asset; presença do arquivo, hash, faixa de IDs ou igualdade do `appearances.dat` não provam que a raster foi escrita.

No formato atual do OTClient, a carga LZMA tem um prefixo CipSoft, propriedades LZMA e um payload BMP 32bpp BGRA. Localize o início do payload analisando o prefixo; não presuma um offset fixo. A bitmap é bottom-up, portanto converta a coordenada visual `y` para a linha `altura - 1 - y`. Alfa zero e magenta transparente contam como invisíveis.

Ao reparar uma folha, preserve uma cópia recuperável do asset original, o `catalog-content.json`, os IDs e a definição de aparência. Reabra o cliente depois da alteração: ele lê o catálogo apenas na inicialização.
