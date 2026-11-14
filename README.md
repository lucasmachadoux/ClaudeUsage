# ClaudeUsage

Widget de área de trabalho para Windows que mostra quanto você já usou dos limites do seu plano do Claude:

- **Sessão · 5 horas**: porcentagem usada e quando a janela reseta
- **Semana**: porcentagem usada e quando o limite semanal reseta

São os mesmos números do comando `/usage` do Claude Code. Eles contam todo o seu uso: Claude Code em qualquer computador e o claude.ai.

Feito em PowerShell + WPF. Não precisa instalar nada.

## Recursos

- Barras coloridas: laranja (normal), amarelo (≥ 60%), vermelho (≥ 85%)
- Contagem regressiva até cada reset
- Atualiza sozinho a cada 3 minutos, com botão para atualizar na hora
- Redimensionável pelas bordas, com o conteúdo se ajustando ao tamanho
- Arrastar para mover, minimizar para a barra de tarefas
- Menu do botão direito: *Atualizar agora*, *Sempre por cima*, *Iniciar com o Windows*, *Minimizar*, *Fechar*

## Requisitos

- Windows 10 ou 11 com Windows PowerShell 5.1 (já vem no Windows)
- Claude Code instalado e logado com uma conta Pro ou Max

## Como usar

1. Baixe ou clone esta pasta.
2. Dê dois cliques em **`ClaudeUsage.vbs`**.
3. Para abrir junto com o Windows, clique com o botão direito no widget → **Iniciar com o Windows**.

## Segurança do seu login

O widget usa o login que o Claude Code salva em `%USERPROFILE%\.claude\.credentials.json`. Toda a parte que mexe com o login está num bloco curto e comentado no topo de `ClaudeUsage.ps1`:

- o arquivo é **só lido**: nunca é alterado, copiado ou renovado;
- o token fica **só na memória** durante a consulta e não é gravado nem exibido;
- ele é enviado **apenas** para `https://api.anthropic.com` (endereço fixo, HTTPS, sem seguir redirecionamentos);
- respostas de erro são descartadas; o arquivo de configuração do widget guarda só a posição e o tamanho da janela.

Se o login expirar, o widget mostra *"Login expirado: abra o Claude Code"*. Basta abrir o Claude Code que ele renova o login, e o widget volta a funcionar sozinho.

> O endereço usado (`/api/oauth/usage`) é o mesmo que o `/usage` do Claude Code consulta, mas não é documentado publicamente e pode mudar.

## Arquivos

| Arquivo | O que é |
|---|---|
| `ClaudeUsage.ps1` | O widget |
| `ClaudeUsage.vbs` | Abre o widget sem a janela preta do PowerShell |

As preferências da janela ficam em `%APPDATA%\ClaudeUsageWidget\config.json`.
