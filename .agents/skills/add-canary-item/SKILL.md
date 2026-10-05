---
name: add-canary-item
description: >-
  Adiciona novos itens customizados ao OTServ Canary (Tibia 13.x/15.x), incluindo
  especificações no items.xml, sincronização de sprites/appearances.dat no servidor e
  cliente, catalog-content.json, e árvore de weapon proficiencies.
---

# Skill: Adicionar Item no Canary (Tibia 13.x / 15.x)

Este guia e automação documenta o fluxo completo para integrar novos itens ao servidor Canary e ao Tibia Client v15.25.

---

## 1. Visão Geral da Arquitetura do Item

Para que um item novo exista e seja usável como os itens nativos (ex: *Grand Sanguine Rod*), ele precisa estar configurado em 4 camadas sincronizadas:

1. **`data/items/items.xml` (Servidor Canary)**:
   - Define ID, atributos de combate, elemento, peso, slots de imbuement, vocação, script de ataque/equipamento (`moveevent;weapon`).
2. **`data/items/appearances.dat` (Servidor Canary)**:
   - Arquivo binário Protobuf que descreve a aparência, flags do item (take, light, clothes, market, weapon type, proficiency ID) e lista de sprite IDs das fases/animação.
3. **Assets do Cliente Tibia (`.tools/tibia-client-15.25/assets/`)**:
   - `sprites-<hash>.bmp.lzma`: Folha de sprites BMP 32bpp bitfields (384x384) comprimida em LZMA formatada com o cabeçalho CipSoft (magic `70 0a fa 80 24`).
   - `appearances-<hash>.dat`: Versão do appearances.dat com o hash SHA-256 no nome do arquivo.
   - `catalog-content.json`: Registra o `appearances-<hash>.dat` e o novo intervalo de sprites.
4. **`data/items/proficiencies.json` (Proficiência de Armas)**:
   - Especifica a árvore de Weapon Proficiency de níveis 1 a 7 (Critical Damage, Extra Damage, Magic Level, Augments de magias, Elemental Pierce, etc.) tanto no servidor quanto no cliente (`proficiencies-*.json`).

---

## 2. Passo a Passo do Procedimento

### Passo 1: Obter a Sprite e Especificações
- Buscar na Wiki oficial ou TibiaWiki BR:
  - Sprite em GIF animado ou PNG das fases.
  - Atributos: dano base (`fromDamage` a `toDamage`), elemento (ice, fire, earth, etc.), requerimentos (nível, vocação), peso, slots de imbuements, bônus de atributos.

### Passo 2: Empacotar a Folha de Sprites (`.bmp.lzma`)
O cliente usa folhas de 384x384 (12x12 = 144 tiles de 32x32 para `spritetype: 0`):
- Fundo transparente: cor magenta `R: 255, G: 0, B: 255, A: 0`.
- Pixels da sprite: BGRA 32bpp.
- Compressão LZMA com props `5d 00 00 00 02` e tamanho do stream em UInt64LE.
- Prefixo CipSoft: `[padding zeroes...] + [70 0a fa 80 24] + [varint(length)]` terminando exatamente no byte 32.
- Hash SHA-256 no nome: `sprites-<sha256>.bmp.lzma`.

### Passo 3: Injetar no `appearances.dat` e no Cliente
- Criar a entrada Protobuf de `Appearance` (tag 1: object id, tag 2: frame group com os novos sprite IDs, tag 3: flags como market, cyclopedia, take, weapon_type, proficiency ID, tag 4: nome do item).
- Atualizar `data/items/appearances.dat`.
- Gerar o SHA-256 e salvar em `.tools/tibia-client-15.25/assets/appearances-<sha256>.dat`.
- Adicionar o sprite e a referência do appearances no `catalog-content.json`.

### Passo 4: Configurar no `items.xml`
Adicionar o bloco `<item id="..." name="...">` com:
```xml
<item id="53221" article="a" name="moonsilver sceptre">
    <attribute key="primarytype" value="rods"/>
    <attribute key="weaponType" value="wand"/>
    <attribute key="shootType" value="ice"/>
    <attribute key="absorbpercentearth" value="7"/>
    <attribute key="magiclevelpoints" value="6"/>
    <attribute key="icemagiclevelpoints" value="1"/>
    <attribute key="healingmagiclevelpoints" value="2"/>
    <attribute key="range" value="6"/>
    <attribute key="weight" value="2800"/>
    <attribute key="imbuementslot" value="2">
        <attribute key="mana leech" value="3"/>
        <attribute key="critical hit" value="3"/>
        <attribute key="skillboost magic level" value="3"/>
    </attribute>
    <attribute key="script" value="moveevent;weapon">
        <attribute key="level" value="1000"/>
        <attribute key="mana" value="20"/>
        <attribute key="unproperly" value="true"/>
        <attribute key="fromDamage" value="103"/>
        <attribute key="toDamage" value="127"/>
        <attribute key="weaponType" value="wand"/>
        <attribute key="wandType" value="ice"/>
        <attribute key="vocation" value="Druid;true, Elder Druid"/>
        <attribute key="slot" value="hand"/>
    </attribute>
</item>
```

### Passo 5: Configurar Proficiência (se aplicável)
- Adicionar a estrutura JSON dos 7 níveis no `data/items/proficiencies.json` e no `proficiencies-*.json` do cliente.

---

## 3. Comandos Úteis de Teste
No jogo pelo client / God:
- `/i moonsilver sceptre` ou `/i 53221`
- Verificar visualização no inventário, look (`You see a moonsilver sceptre...`), disparo elemental com Druid level 1000+ e Cyclopedia / Market.

