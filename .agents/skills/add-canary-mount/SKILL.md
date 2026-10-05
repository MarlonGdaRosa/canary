---
name: add-canary-mount
description: >-
  Adiciona novas montarias customizadas ao OTServ Canary (Tibia 13.x/15.x),
  incluindo download e separação das 4 direções de sprites 64x64, interpolação correta
  de frames de animação, injeção no appearances.dat, sincronização de catalog-content.json/lzma,
  data/XML/mounts.xml e itens de domar.
---

# Skill: Adicionar Montaria no Canary (Tibia 13.x / 15.x)

Este guia documenta o padrão definitivo e à prova de falhas para adicionar montarias no OTServ Canary e no Tibia Client v15.25, garantindo que o visual, as 4 direções (Norte, Leste, Sul, Oeste) e as animações funcionem perfeitamente de primeira.

---

## 1. Visão Geral da Arquitetura de Montarias

Uma montaria no Canary e no Tibia Client depende de 5 componentes sincronizados:

1. **`data/XML/mounts.xml` (Servidor)**:
   - Define o ID interno da montaria (`mount id`) e o ID visual do cliente (`clientid` / looktype):
     ```xml
     <mount id="237" clientid="1975" name="Radiant Nimbus" speed="10" premium="yes" type="quest" />
     ```
2. **`data/items/appearances.dat` (Servidor e Cliente)**:
   - Contém a definição Protobuf de `Outfit` (tag 2 do arquivo).
   - Possui 2 `FrameGroup`:
     - `FrameGroup 0` (parado / idle): `pattern_width = 4` (as 4 direções), 8 fases de animação = 32 sprites.
     - `FrameGroup 1` (em movimento / walk): `pattern_width = 4`, 8 fases de animação = 32 sprites (geralmente compartilha alguns sprites com o FG 0).
3. **Folhas de Sprites 64x64 (`spritetype: 3`) nos Assets do Cliente (`.tools/tibia-client-15.25/assets/`)**:
   - Montarias utilizam sprites 64x64 (`spritetype: 3`).
   - Cada folha tem dimensões **384x384** (grade de 6x6 = até 36 sprites de 64x64 por folha).
   - Formato: BMP bitfields 32bpp BGRA com fundo transparente magenta (`#FF00FF00`), comprimido com LZMA no padrão CipSoft (`magic 70 0a fa 80 24`).
4. **Catálogo de Assets (`catalog-content.json` e `catalog-content.json.lzma`)**:
   - Registra o arquivo `appearances-<hash>.dat` atualizado e os novos arquivos `sprites-<hash>.bmp.lzma`.
   - **MANDATÓRIO**: Fechar qualquer processo ativo do `client.exe` antes de abrir o jogo, pois o cliente **só carrega o catálogo uma vez na inicialização**.
5. **Item de Domar / Usar (Opcional, ex: Cloud in a Bottle)**:
   - `data/items/items.xml`: item do tipo `taming items`.
   - `data/scripts/actions/items/usable_mount_items.lua`: vincula o item à montaria (`mountId`).
   - `data/scripts/lib/register_achievements.lua`: registro de conquista obtida ao domar.

---

## 2. A REGRA DE OURO: Intercalação de Sprites (Evitar Rotação Fantasma)

> [!CAUTION]
> **NUNCA agrupe os sprites sequencialmente por direção (ex: todos do Norte, depois todos do Leste).**
> Se fizer isso, a montaria ficará girando em 360° continuamente sem parar!

### A Fórmula do Motor do Tibia
No motor C++ do Tibia Client (conforme `ThingType::getSpriteIndex`):
$$\text{Index} = (\text{animPhase} \times \text{pattern\_width}) + \text{direction}$$
onde:
- `pattern_width = 4`
- `direction`: **0 = Norte**, **1 = Leste**, **2 = Sul**, **3 = Oeste**
- `animPhase`: **0 a 7** (para animações de 8 frames)

Portanto, a ordem dos sprites no array Protobuf e nas folhas **DEVE SER INTERCALADA**:
```
Index  0 (anim=0, Norte) -> Sprite 1
Index  1 (anim=0, Leste) -> Sprite 2
Index  2 (anim=0, Sul)   -> Sprite 3
Index  3 (anim=0, Oeste) -> Sprite 4

Index  4 (anim=1, Norte) -> Sprite 5
Index  5 (anim=1, Leste) -> Sprite 6
Index  6 (anim=1, Sul)   -> Sprite 7
Index  7 (anim=1, Oeste) -> Sprite 8
...
Index 28 (anim=7, Norte) -> Sprite 29
Index 29 (anim=7, Leste) -> Sprite 30
Index 30 (anim=7, Sul)   -> Sprite 31
Index 31 (anim=7, Oeste) -> Sprite 32
```
Dessa forma, quando o jogador estiver virado para o **Norte** (`direction = 0`), o cliente selecionará estritamente os índices `0, 4, 8, 12, 16, 20, 24, 28` à medida que a animação passa, mantendo a montaria estável na direção correta.

---

## 3. Mapeamento das 4 Direções do GIF da TibiaWiki

Ao baixar o GIF oficial da montaria da TibiaWiki (ex: 96 frames, 64x64):
- O GIF é composto por **12 blocos de 8 frames** (total 96 frames).
- Cada direção possui 8 frames de animação e é repetida 3 vezes no GIF (0=1=2, 3=4=5, 6=7=8, 9=10=11).
- **Ordem de rotação padrão nos GIFs da TibiaWiki**:
  - **Bloco 0 (frames 0..7)**: **SUL** (`Direction 2` - frente para a câmera / visor da sela aberto para cima).
  - **Bloco 3 (frames 24..31)**: **LESTE** (`Direction 1` - perfil para a direita, cauda/vento para a esquerda).
  - **Bloco 6 (frames 48..55)**: **NORTE** (`Direction 0` - costas para a câmera / subindo).
  - **Bloco 9 (frames 72..79)**: **OESTE** (`Direction 3` - perfil para a esquerda, cauda/vento para a direita).

> [!TIP]
> Para baixar o GIF completo sem compressão do Cloudflare:
> ```bash
> curl.exe -s -L -H "User-Agent: Mozilla/5.0" -H "Referer: https://tibia.fandom.com/" -o "mount.gif" "<URL_DO_GIF>&format=original"
> ```

---

## 4. Passo a Passo Completo de Implementação

### Passo 1: Localizar o Client ID (LookType) da Montaria
1. Procure no arquivo de referência limpo do cliente (`.tools/tibia-client-15.25/assets/appearances-*.dat`).
2. Muitas vezes a CipSoft já criou a definição do outfit com os IDs de sprite originais (ex: looktype 1975 com 52 sprites `140371..140422`), mas ainda não incluiu os sprites na versão local.
3. Se o outfit já existir no dat de referência, reaproveite o payload e apenas remapeie os sprite IDs para a nova faixa disponível.

### Passo 2: Calcular a Nova Faixa de Sprite IDs
1. Abra `catalog-content.json`.
2. Encontre o maior `lastspriteid` existente entre todos os registros de `type: "sprite"`.
3. Inicie os novos sprites em `maxSpriteId + 1`.
   - Para montarias típicas com 52 sprites:
     - **Folha 1** (`spritetype: 3`, 36 sprites): IDs `startId` até `startId + 35`.
     - **Folha 2** (`spritetype: 3`, 16 sprites): IDs `startId + 36` até `startId + 51`.

### Passo 3: Montar as Folhas BMP 32bpp e Comprimir em LZMA
Cada folha 64x64 deve ser montada como BMP 384x384 (6x6 sprites):
- Fundo transparente: `#FF00FF00` (Blue: 0xFF, Green: 0x00, Red: 0xFF, Alpha: 0x00).
- Compressão CipSoft LZMA:
  - Propriedades LZMA: `5d 00 00 00 02` a partir do offset 32.
  - Varint length com magic CipSoft `70 0a fa 80 24`.
  - Salvar em `.tools/tibia-client-15.25/assets/sprites-<sha256>.bmp.lzma`.

### Passo 4: Atualizar `data/items/appearances.dat` e Cliente
1. Remapear os IDs no payload Protobuf do Outfit.
2. Concatenar no final de `data/items/appearances.dat`.
3. Calcular o hash SHA-256 do arquivo resultante.
4. Salvar uma cópia idêntica em `.tools/tibia-client-15.25/assets/appearances-<sha256>.dat`.

### Passo 5: Atualizar o Catálogo e Comprimir em LZMA
1. Atualizar o registro `type: "appearances"` no `catalog-content.json` com o novo nome `appearances-<sha256>.dat`.
2. Adicionar os 2 novos blocos de `type: "sprite"` com `spritetype: 3`.
3. Salvar `catalog-content.json`.
4. Comprimir `catalog-content.json` no formato CipSoft LZMA e salvar em `catalog-content.json.lzma`.

### Passo 6: Configurar Servidor
1. **`data/XML/mounts.xml`**:
   ```xml
   <mount id="<ID>" clientid="<LOOKTYPE>" name="<NOME>" speed="10" premium="yes" type="quest" />
   ```
2. **Item de Domar (se aplicável)**:
   - Configurar o item em `data/items/items.xml`.
   - Adicionar em `data/scripts/actions/items/usable_mount_items.lua`.
   - Adicionar achievement em `data/scripts/lib/register_achievements.lua`.

### Passo 7: Reiniciar Cliente e Servidor
1. Finalizar qualquer instância do cliente aberta:
   ```powershell
   Stop-Process -Name client -Force -ErrorAction SilentlyContinue
   ```
2. Iniciar o servidor (`iniciar-servidor.bat`).
3. Abrir o cliente do jogo.

---

## 5. Script Modelo de Automação (Node.js)

Abaixo está o template padronizado para execução do processo:

```javascript
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const LZMA = require('./node_modules/lzma');
const { GifReader } = require('./node_modules/omggif');

function build64Sheet(frames) {
  const width = 384, height = 384;
  const pixelBytes = width * height * 4;
  const bmpBuffer = Buffer.alloc(122 + pixelBytes);
  // Cabeçalho BMP 32bpp bitfields
  bmpBuffer.write('BM', 0);
  bmpBuffer.writeUInt32LE(122 + pixelBytes, 2);
  bmpBuffer.writeUInt32LE(122, 10);
  bmpBuffer.writeUInt32LE(108, 14);
  bmpBuffer.writeInt32LE(width, 18);
  bmpBuffer.writeInt32LE(height, 22);
  bmpBuffer.writeUInt16LE(1, 26);
  bmpBuffer.writeUInt16LE(32, 28);
  bmpBuffer.writeUInt32LE(3, 30);
  bmpBuffer.writeUInt32LE(pixelBytes, 34);
  bmpBuffer.writeUInt32LE(0x00FF0000, 54);
  bmpBuffer.writeUInt32LE(0x0000FF00, 58);
  bmpBuffer.writeUInt32LE(0x000000FF, 62);
  bmpBuffer.writeUInt32LE(0xFF000000, 66);

  // Fundo Magenta Transparente
  for (let i = 0; i < width * height; i++) {
    const off = 122 + i * 4;
    bmpBuffer[off] = 0xFF; bmpBuffer[off + 1] = 0x00; bmpBuffer[off + 2] = 0xFF; bmpBuffer[off + 3] = 0x00;
  }

  // Preencher grade 6x6
  for (let f = 0; f < frames.length; f++) {
    const frame = frames[f];
    const col = f % 6, row = Math.floor(f / 6);
    for (let dy = 0; dy < 64; dy++) {
      for (let dx = 0; dx < 64; dx++) {
        const px = col * 64 + dx, py = row * 64 + dy;
        const off = 122 + ((383 - py) * 384 + px) * 4;
        const sOff = (dy * 64 + dx) * 4;
        if (frame[sOff + 3] > 0) {
          bmpBuffer[off] = frame[sOff + 2];     // B
          bmpBuffer[off + 1] = frame[sOff + 1]; // G
          bmpBuffer[off + 2] = frame[sOff];     // R
          bmpBuffer[off + 3] = frame[sOff + 3]; // A
        }
      }
    }
  }
  return bmpBuffer;
}

function compressToCipLzma(buffer) {
  return new Promise((resolve, reject) => {
    LZMA.compress(buffer, 1, (result, err) => {
      if (err) return reject(err);
      const raw = Buffer.from(result);
      const stream = raw.slice(13);
      const streamLen = stream.length;
      let val = 13 + streamLen, varint = [];
      while (val > 0) {
        let b = val & 0x7F; val >>>= 7; if (val > 0) b |= 0x80; varint.push(b);
      }
      const p = 32 - 5 - varint.length;
      const file = Buffer.alloc(32 + 13 + streamLen);
      Buffer.from('700afa8024', 'hex').copy(file, p);
      Buffer.from(varint).copy(file, p + 5);
      Buffer.from('5d00000002', 'hex').copy(file, 32);
      file.writeBigUInt64LE(BigInt(streamLen), 37);
      stream.copy(file, 45);
      const hash = crypto.createHash('sha256').update(file).digest('hex');
      resolve({ hash, buffer: file });
    });
  });
}
```

---

## 6. Checklist de Validação Final
Antes de considerar o trabalho concluído, execute as seguintes verificações:
- [ ] O `mounts.xml` contém o `clientid` correto correspondente ao looktype.
- [ ] O arquivo `appearances.dat` do servidor e do cliente possuem exatamente o mesmo SHA-256.
- [ ] O `catalog-content.json` lista o `appearances-<sha256>.dat` e ambas as folhas de sprites (`spritetype: 3`).
- [ ] O `catalog-content.json.lzma` foi regerado a partir do JSON atualizado.
- [ ] O `client.exe` foi fechado e reaberto para recarregar o catálogo da memória.
- [ ] Ao montar no jogo, virar para Norte, Leste, Sul e Oeste exibe cada direção estavelmente sem rotação automática.
