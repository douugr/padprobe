# PadProbe

Ferramenta de diagnóstico para descobrir como um **controle Bluetooth** conversa com um **iPad antigo (iOS 8, jailbreak)** pelo [BTstack](https://github.com/bluekitchen/btstack).

O app procura dispositivos, conecta no controle (HID por L2CAP) e mostra os relatórios brutos em hexadecimal. Você marca o "repouso" e aperta um botão por vez, e ele destaca quais bytes e bits mudaram. Foi assim que o formato do 8BitDo Pro 2 foi mapeado para o [MD16](https://github.com/douugr/md16).

## Requisitos

- iPad com iOS 8 e jailbreak, com OpenSSH e o pacote **BTstack** (`ch.ringwald.btstack` 1.1)
- Mac com o Xcode 13.4.1 extraído (toolchain armv7) e `ldid`

## Compilar e instalar

```bash
export X13=/caminho/para/Xcode-13.4.1.app/Contents/Developer
./build.sh install
```

O app é instalado em `/Applications`, fora do sandbox, para poder falar com o BTdaemon. A `libBTstack.dylib` é copiada do próprio iPad e não é versionada.

Antes de usar, deixe o Bluetooth do iOS desligado em Ajustes. O botão "Salvar" grava o registro em `Documents/padprobe.txt`.

## Licença

Os headers em `vendor/btstack` são do BTstack (© BlueKitchen GmbH / Matthias Ringwald) e seguem a licença dele.
