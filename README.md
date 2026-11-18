# ClaudeUsage

Widget de área de trabalho para Windows que mostra quanto você já usou dos limites do seu plano do Claude:

- **Sessão · 5 horas**: porcentagem usada e quando a janela reseta
- **Semana**: porcentagem usada e quando o limite semanal reseta

São os mesmos números do comando `/usage` do Claude Code. Eles contam todo o seu uso: Claude Code em qualquer computador e o claude.ai.

Feito em PowerShell + WPF. Não precisa instalar nada.

## Recursos

- Mostra no topo **qual conta** está sendo exibida (organização ou e-mail, e o plano). Passe o mouse para ver os detalhes
- Barras coloridas: laranja (normal), amarelo (≥ 60%), vermelho (≥ 85%)
- Contagem regressiva até cada reset
- Atualiza sozinho a cada 3 minutos, com botão para atualizar na hora
- Redimensionável pelas bordas, com o conteúdo se ajustando ao tamanho
- Arrastar para mover, minimizar para a barra de tarefas
- Menu do botão direito: *Atualizar agora*, *Sempre por cima*, *Iniciar com o Windows*, *Minimizar*, *Fechar*

## Requisitos

- Windows 10 ou 11 com Windows PowerShell 5.1 (já vem no Windows)
- Claude Code instalado e logado com uma conta Pro ou Max

## Instalação

1. Baixe o projeto (**Code → Download ZIP**) e extraia a pasta num lugar fixo, por exemplo `Documentos\ClaudeUsage`.
   Os atalhos apontam para essa pasta, então não a mova depois de instalar (se mover, é só rodar o instalador de novo).
2. Dê dois cliques em **`Instalar.cmd`**. Ele:
   - cria o atalho **Uso do Claude** na área de trabalho, com ícone próprio;
   - desbloqueia os arquivos baixados da internet;
   - abre o widget.
3. Para abrir junto com o Windows: botão direito no widget → **Iniciar com o Windows**.

> O Windows pode mostrar o aviso *"O Windows protegeu o computador"* ao abrir um `.cmd` baixado. Clique em **Mais informações → Executar assim mesmo**.

### Desinstalar

Dê dois cliques em **`Desinstalar.cmd`**. Ele fecha o widget e remove os atalhos (área de trabalho e inicialização) e as preferências da janela. Depois é só apagar a pasta. O seu login do Claude Code não é tocado.

## Várias contas

O widget mostra a conta que está logada no **Claude Code do terminal**. Para trocar:

1. Rode `claude` no terminal.
2. Use `/login` e entre com a outra conta.

O widget percebe a troca sozinho em poucos segundos: descarta os números da conta anterior e mostra os da nova.

> O app de desktop do Claude guarda o login dele de forma criptografada, então o widget não consegue seguir a conta aberta lá. Ele segue sempre a do terminal.

## Segurança do seu login

O widget usa o login que o Claude Code salva em `%USERPROFILE%\.claude\.credentials.json`. Toda a parte que mexe com o login está num bloco curto e comentado no topo de `ClaudeUsage.ps1`:

- os tokens ficam **só na memória**: nunca são exibidos, registrados ou copiados para outro lugar;
- o token de acesso vai **apenas** para `https://api.anthropic.com`, e o de renovação **apenas** para `https://platform.claude.com` (endereços fixos, HTTPS, sem seguir redirecionamentos);
- respostas de erro são descartadas; o arquivo de configuração do widget guarda só a posição e o tamanho da janela.

### Renovação automática do login

O login do Claude Code vale poucas horas. Quem o renova normalmente é o próprio Claude Code, mas só quando ele está aberto (o app de desktop do Claude não atualiza esse arquivo). Para o widget não parar, ele renova o login **do mesmo jeito que o Claude Code** e grava o login novo no mesmo arquivo:

- só renova quando o login **já venceu**, para não disputar com um Claude Code aberto (que renova antes de vencer);
- no máximo uma tentativa a cada 5 minutos;
- antes de gravar, relê o arquivo: se o Claude Code renovou nesse meio-tempo, mantém o dele;
- a gravação é atômica (escreve ao lado e troca de uma vez), então o arquivo nunca fica pela metade.

Se a renovação for recusada, o widget mostra *"Login inválido: rode "claude" no terminal e entre de novo"*.

> Os endereços usados (`/api/oauth/usage` e `/v1/oauth/token`) são os mesmos que o Claude Code usa, mas não são documentados publicamente e podem mudar.

## Arquivos

| Arquivo | O que é |
|---|---|
| `Instalar.cmd` / `Desinstalar.cmd` | Instalam ou removem os atalhos |
| `install.ps1` | O script usado por esses dois |
| `ClaudeUsage.ps1` | O widget |
| `ClaudeUsage.vbs` | Abre o widget sem a janela preta do PowerShell |
| `ClaudeUsage.ico` | Ícone do atalho |

As preferências da janela ficam em `%APPDATA%\ClaudeUsageWidget\config.json`.
