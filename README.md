# KeychronMapper

App de barra de menu que faz o Mac entender o Keychron C1 Pro 8K (ANSI, QMK).

- Com um Keychron conectado: troca a fonte de entrada para **U.S. International – PC**, para que cada tecla produza o que está impresso nela.
- F1–F12 do Keychron viram teclas de função comuns: o app traduz os comandos de sistema que o firmware envia no modo Mac (brilho, Mission Control, Launchpad, mídia). Isso vale só para o Keychron e só enquanto o app estiver rodando.
- Sem Keychron (ou ao sair do app): volta para a fonte anterior (ex.: Brasileiro – Pro). O teclado interno do Mac não é afetado.
- Se o macOS tiver cadastrado o teclado como ISO, o menu oferece **Corrigir para ANSI…**.

Acentos no U.S. International – PC: `'` + `c` = ç, `'` + `a` = á, `~` + `a` = ã, `^` + `e` = ê, `` ` `` + `a` = à. Para digitar o próprio símbolo, use o símbolo + espaço.

## Build

```sh
./build.sh           # gera build/KeychronMapper.app
./build.sh install   # instala em /Applications e abre
```

Para abrir automaticamente no login: menu do app → **Abrir ao iniciar sessão**.

## Licença

MIT — veja [LICENSE](LICENSE).
