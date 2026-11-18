# ClaudeUsage - mostra o uso dos limites do Claude (janela de 5 horas e semanal)
# Abra pelo arquivo ClaudeUsage.vbs (sem janela de console).

$ErrorActionPreference = 'Stop'

# ---------- instância única ----------
$mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeUsageWidget_SingleInstance')
if (-not $mutex.WaitOne(0)) { exit }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Net.Http

# ---------- consulta à Anthropic ----------
# ÚNICA parte do widget que toca no login. Regras:
#   - lê o arquivo de login do Claude Code; os tokens ficam só na memória e nunca são exibidos
#     nem copiados para outro lugar;
#   - o token de acesso só é enviado para https://api.anthropic.com e o refresh token só para
#     https://platform.claude.com (endereços fixos, HTTPS, sem seguir redirecionamentos);
#   - quando o login JÁ venceu, renova do mesmo jeito que o Claude Code e grava o login novo
#     no mesmo arquivo (troca atômica), para o Claude Code continuar funcionando;
#   - respostas de erro são descartadas; o widget guarda só o código do erro.
$cs = @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace ClaudeUsage {
  public class Result { public int Status; public string Body; public string Error; }

  public static class Api {
    const string Url = "https://api.anthropic.com/api/oauth/usage";
    static readonly HttpClient http;

    static Api() {
      ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
      http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(15) };
    }

    static string CredentialsPath() {
      string dir = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
      if (string.IsNullOrEmpty(dir))
        dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
      return Path.Combine(dir, ".credentials.json");
    }

    static string ReadFile(string path) {
      using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
      using (var sr = new StreamReader(fs)) return sr.ReadToEnd();
    }

    static string Field(string json, string name) {
      var m = Regex.Match(json, "\"" + name + "\"\\s*:\\s*\"([^\"]+)\"");
      return m.Success ? m.Groups[1].Value : null;
    }

    // Devolve o token de acesso; error = "nologin" ou "expired" quando não há um válido.
    static string ReadToken(out string error) {
      error = null;
      string path = CredentialsPath();
      if (!File.Exists(path)) { error = "nologin"; return null; }
      string json = ReadFile(path);
      string tok = Field(json, "accessToken");
      if (tok == null) { error = "nologin"; return null; }
      var exp = Regex.Match(json, "\"expiresAt\"\\s*:\\s*(\\d+)");
      if (exp.Success && long.Parse(exp.Groups[1].Value) < DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()) { error = "expired"; return null; }
      return tok;
    }

    // ---------- renovação do login ----------
    // Faz o mesmo que o Claude Code faz quando o login vence: troca o refresh token
    // por um token novo em platform.claude.com e grava o resultado no mesmo arquivo,
    // para o Claude Code continuar usando. Só roda com o login JÁ vencido (assim não
    // disputa com um Claude Code aberto, que renova antes de vencer) e no máximo a cada 5 min.
    const string TokenUrl = "https://platform.claude.com/v1/oauth/token";
    const string ClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
    const string Scopes   = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";
    static DateTime lastRefresh = DateTime.MinValue;

    // Devolve null se deu certo; senão "expired", "relogin" ou "network".
    static async Task<string> Refresh() {
      if (DateTime.UtcNow - lastRefresh < TimeSpan.FromMinutes(5)) return "expired";
      lastRefresh = DateTime.UtcNow;
      string path = CredentialsPath();
      string refresh = Field(ReadFile(path), "refreshToken");
      if (refresh == null) return "relogin";

      string body = "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"" + refresh +
                    "\",\"client_id\":\"" + ClientId + "\",\"scope\":\"" + Scopes + "\"}";
      string resp;
      try {
        using (var req = new HttpRequestMessage(HttpMethod.Post, TokenUrl)) {
          req.Content = new StringContent(body, System.Text.Encoding.UTF8, "application/json");
          req.Headers.UserAgent.ParseAdd("ClaudeUsageWidget/1.0");
          using (var r = await http.SendAsync(req).ConfigureAwait(false)) {
            int st = (int)r.StatusCode;
            if (st == 400 || st == 401 || st == 403) return "relogin";
            if (st != 200) return "expired";
            resp = await r.Content.ReadAsStringAsync().ConfigureAwait(false);
          }
        }
      } catch { return "network"; }
      finally { body = null; }

      string access = Field(resp, "access_token");
      string newRefresh = Field(resp, "refresh_token") ?? refresh;
      var expIn = Regex.Match(resp, "\"expires_in\"\\s*:\\s*(\\d+)");
      var rtExpIn = Regex.Match(resp, "\"refresh_token_expires_in\"\\s*:\\s*(\\d+)");
      resp = null;
      if (access == null || !expIn.Success) return "expired";
      long expiresAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + long.Parse(expIn.Groups[1].Value) * 1000;

      // Relê o arquivo: se o Claude Code renovou nesse meio-tempo, mantém o dele.
      string json = ReadFile(path);
      if (Field(json, "refreshToken") != refresh) return null;
      json = Regex.Replace(json, "(\"accessToken\"\\s*:\\s*\")[^\"]+(\")",  m => m.Groups[1].Value + access + m.Groups[2].Value);
      json = Regex.Replace(json, "(\"refreshToken\"\\s*:\\s*\")[^\"]+(\")", m => m.Groups[1].Value + newRefresh + m.Groups[2].Value);
      json = Regex.Replace(json, "(\"expiresAt\"\\s*:\\s*)\\d+",           m => m.Groups[1].Value + expiresAt);
      if (rtExpIn.Success) {
        long rtExpiresAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + long.Parse(rtExpIn.Groups[1].Value) * 1000;
        json = Regex.Replace(json, "(\"refreshTokenExpiresAt\"\\s*:\\s*)\\d+", m => m.Groups[1].Value + rtExpiresAt);
      }

      // Gravação atômica: escreve ao lado e troca de uma vez (nunca deixa o arquivo pela metade).
      string tmp = path + ".widget-tmp";
      try {
        File.WriteAllText(tmp, json, new System.Text.UTF8Encoding(false));
        File.Replace(tmp, path, null);
      } catch { try { File.Delete(tmp); } catch {} return "expired"; }
      return null;
    }

    static async Task<int> Query(Result r, string token) {
      using (var req = new HttpRequestMessage(HttpMethod.Get, Url)) {
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        req.Headers.Add("anthropic-beta", "oauth-2025-04-20");
        req.Headers.Accept.ParseAdd("application/json");
        req.Headers.UserAgent.ParseAdd("ClaudeUsageWidget/1.0");
        using (var resp = await http.SendAsync(req).ConfigureAwait(false)) {
          r.Status = (int)resp.StatusCode;
          r.Body = r.Status == 200 ? await resp.Content.ReadAsStringAsync().ConfigureAwait(false) : null;
          return r.Status;
        }
      }
    }

    public static async Task<Result> Fetch() {
      var r = new Result();
      try {
        string err;
        string token = ReadToken(out err);
        bool refreshed = false;
        if (token == null && err == "expired") {
          string e = await Refresh().ConfigureAwait(false);
          if (e != null) { r.Error = e; return r; }
          refreshed = true;
          token = ReadToken(out err);
        }
        if (token == null) { r.Error = err; return r; }
        int st = await Query(r, token).ConfigureAwait(false);
        if (st == 401 && !refreshed) {
          // Token recusado antes da hora: tenta renovar uma vez.
          lastRefresh = DateTime.MinValue;
          string e = await Refresh().ConfigureAwait(false);
          if (e != null) { r.Error = e; return r; }
          token = ReadToken(out err);
          if (token == null) { r.Error = err; return r; }
          await Query(r, token).ConfigureAwait(false);
        }
        token = null;
      } catch { r.Error = "network"; }
      return r;
    }
  }
}
'@
if (-not ('ClaudeUsage.Api' -as [type])) {
  Add-Type -TypeDefinition $cs -Language CSharp -ReferencedAssemblies System.Net.Http
}

# ---------- configuração (só preferências da janela; nada de login) ----------
$cfgDir  = Join-Path $env:APPDATA 'ClaudeUsageWidget'
$cfgPath = Join-Path $cfgDir 'config.json'
$state = @{
  Topmost = $true; Left = $null; Top = $null; Width = $null; Height = $null
  Data = $null; Task = $null; NextFetch = [DateTime]::MinValue; LastFetch = [DateTime]::MinValue
  LastOk = $null; Message = 'carregando…'; MessageBad = $false; LastRender = [DateTime]::MinValue; Dirty = $false
}
if (Test-Path $cfgPath) {
  try {
    $c = Get-Content $cfgPath -Raw | ConvertFrom-Json
    foreach ($k in 'Topmost','Left','Top','Width','Height') { if ($null -ne $c.$k) { $state[$k] = $c.$k } }
  } catch {}
}
function Save-Config {
  try {
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory $cfgDir | Out-Null }
    $cfg = @{ Topmost = $state.Topmost; Left = $window.Left; Top = $window.Top }
    if ($state.BaseW) { $cfg.Width = $window.ActualWidth; $cfg.Height = $window.ActualHeight }
    $state.Dirty = $false
    $cfg | ConvertTo-Json | Set-Content $cfgPath -Encoding UTF8
  } catch {}
}

$vbsPath    = Join-Path $PSScriptRoot 'ClaudeUsage.vbs'
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'ClaudeUsage.lnk'

# ---------- interface ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ClaudeUsage" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ResizeMode="CanResize" SizeToContent="WidthAndHeight"
        FontFamily="Segoe UI Variable Text, Segoe UI" UseLayoutRounding="True">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="0" ResizeBorderThickness="10" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#9AA0A6"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Width" Value="22"/>
      <Setter Property="Height" Value="22"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="bd" CornerRadius="6" Background="{TemplateBinding Background}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#2A2C33"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.7"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#9AA0A6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalAlignment" Value="Bottom"/>
      <Setter Property="Margin" Value="0,0,0,3"/>
    </Style>
    <Style x:Key="Pct" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#F1F3F4"/>
      <Setter Property="FontSize" Value="20"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Small" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#80868B"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="0,5,0,0"/>
    </Style>
  </Window.Resources>

  <Grid Background="#01000000">
  <Border x:Name="Card" Margin="10" CornerRadius="12" Background="#1C1D22" BorderBrush="#30333B" BorderThickness="1" Padding="12,7,10,11">
    <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="3" Opacity="0.45"/></Border.Effect>
    <StackPanel x:Name="Root" Width="236" VerticalAlignment="Center">

      <DockPanel>
        <Button x:Name="BtnClose" DockPanel.Dock="Right" Style="{StaticResource Btn}" ToolTip="Fechar">
          <TextBlock Text="&#xE8BB;" FontFamily="{StaticResource Icons}" FontSize="10"/>
        </Button>
        <Button x:Name="BtnMin" DockPanel.Dock="Right" Style="{StaticResource Btn}" ToolTip="Minimizar" Margin="0,0,2,0">
          <TextBlock Text="&#xE921;" FontFamily="{StaticResource Icons}" FontSize="10"/>
        </Button>
        <Button x:Name="BtnRefresh" DockPanel.Dock="Right" Style="{StaticResource Btn}" ToolTip="Atualizar agora" Margin="0,0,2,0">
          <TextBlock x:Name="RefreshIcon" Text="&#xE72C;" FontFamily="{StaticResource Icons}" FontSize="11"/>
        </Button>
        <Ellipse Width="8" Height="8" Fill="#D97757" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <TextBlock Text="Uso do Claude" Foreground="#9AA0A6" FontSize="12" VerticalAlignment="Center"/>
      </DockPanel>

      <!-- Limite de 5 horas -->
      <DockPanel Margin="0,8,0,0">
        <TextBlock x:Name="SPct" DockPanel.Dock="Right" Text="--" Style="{StaticResource Pct}"/>
        <TextBlock Text="Sessão · 5 horas" Style="{StaticResource Label}"/>
      </DockPanel>
      <Grid Height="6" Margin="0,4,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition x:Name="SCol0" Width="0*"/><ColumnDefinition x:Name="SCol1" Width="1*"/></Grid.ColumnDefinitions>
        <Border Grid.ColumnSpan="2" CornerRadius="3" Background="#3A3D46"/>
        <Border x:Name="SFill" Grid.Column="0" CornerRadius="3" Background="#D97757"/>
      </Grid>
      <TextBlock x:Name="SReset" Text=" " Style="{StaticResource Small}"/>

      <!-- Limite semanal -->
      <DockPanel Margin="0,10,0,0">
        <TextBlock x:Name="WPct" DockPanel.Dock="Right" Text="--" Style="{StaticResource Pct}"/>
        <TextBlock Text="Semana" Style="{StaticResource Label}"/>
      </DockPanel>
      <Grid Height="6" Margin="0,4,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition x:Name="WCol0" Width="0*"/><ColumnDefinition x:Name="WCol1" Width="1*"/></Grid.ColumnDefinitions>
        <Border Grid.ColumnSpan="2" CornerRadius="3" Background="#3A3D46"/>
        <Border x:Name="WFill" Grid.Column="0" CornerRadius="3" Background="#D97757"/>
      </Grid>
      <TextBlock x:Name="WReset" Text=" " Style="{StaticResource Small}"/>

      <Border Height="1" Background="#2A2C33" Margin="0,10,0,0"/>
      <TextBlock x:Name="Footer" Text="carregando…" Foreground="#6F757B" FontSize="10.5" Margin="0,7,0,0" TextTrimming="CharacterEllipsis"/>
    </StackPanel>
  </Border>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'Card','Root','BtnClose','BtnMin','BtnRefresh','RefreshIcon','SPct','SCol0','SCol1','SFill','SReset','WPct','WCol0','WCol1','WFill','WReset','Footer') {
  $ui[$n] = $window.FindName($n)
}

$bc = [Windows.Media.BrushConverter]::new()
$brushOk   = $bc.ConvertFrom('#D97757')   # laranja Claude
$brushMid  = $bc.ConvertFrom('#F5A524')   # amarelo: a partir de 60%
$brushHigh = $bc.ConvertFrom('#EF5350')   # vermelho: a partir de 85%
$brushFoot = $bc.ConvertFrom('#6F757B')
$ptBR = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')

# ---------- posição ----------
$window.Topmost = [bool]$state.Topmost
$window.WindowStartupLocation = 'Manual'
if ($null -ne $state.Left -and $null -ne $state.Top) {
  $window.Left = [double]$state.Left
  $window.Top  = [double]$state.Top
} else {
  $wa = [System.Windows.SystemParameters]::WorkArea
  $window.Left = $wa.Right - 300
  $window.Top  = $wa.Top + 20
}

# ---------- exibição ----------
function Format-Left([TimeSpan]$t) {
  if ($t.TotalMinutes -lt 1) { return 'menos de 1 min' }
  if ($t.TotalHours -lt 1)   { return '{0} min' -f [int][Math]::Floor($t.TotalMinutes) }
  if ($t.TotalDays -lt 1)    { return '{0}h {1:00}min' -f [int][Math]::Floor($t.TotalHours), $t.Minutes }
  return '{0}d {1}h' -f [int][Math]::Floor($t.TotalDays), $t.Hours
}

function Get-ResetTime($v) {
  if ($null -eq $v -or "$v" -eq '') { return $null }
  if ($v -is [DateTime]) { return $v.ToLocalTime() }
  try { return ([DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime } catch { return $null }
}

function Show-Limit($d, $pctTb, $col0, $col1, $fill, $resetTb, [bool]$weekly) {
  if ($null -eq $d) {
    $pctTb.Text = '--'
    $col0.Width = New-Object System.Windows.GridLength(0, 'Star')
    $col1.Width = New-Object System.Windows.GridLength(1, 'Star')
    $resetTb.Text = ' '
    return
  }
  $u = 0.0; if ($null -ne $d.utilization) { $u = [double]$d.utilization }
  $p = [Math]::Max(0.0, [Math]::Min(100.0, $u))
  $pctTb.Text = '{0:0}%' -f $u
  $col0.Width = New-Object System.Windows.GridLength($p, 'Star')
  $col1.Width = New-Object System.Windows.GridLength((100 - $p), 'Star')
  $brush = if ($u -ge 85) { $brushHigh } elseif ($u -ge 60) { $brushMid } else { $brushOk }
  $fill.Background = $brush
  $pctTb.Foreground = if ($u -ge 85) { $brushHigh } else { [Windows.Media.Brushes]::WhiteSmoke }

  $t = Get-ResetTime $d.resets_at
  if ($null -eq $t) {
    $resetTb.Text = if ($u -le 0) { 'sem uso nesta janela' } else { ' ' }
  } else {
    $left = $t - (Get-Date)
    if ($left.TotalSeconds -le 0) { $resetTb.Text = 'resetando…' }
    elseif ($weekly) { $resetTb.Text = 'reseta {0} · em {1}' -f $t.ToString('ddd HH:mm', $ptBR), (Format-Left $left) }
    else { $resetTb.Text = 'reseta às {0} · em {1}' -f $t.ToString('HH:mm'), (Format-Left $left) }
  }
}

function Render {
  $state.LastRender = Get-Date
  $d = $state.Data
  Show-Limit $(if ($d) { $d.five_hour } else { $null }) $ui.SPct $ui.SCol0 $ui.SCol1 $ui.SFill $ui.SReset $false
  Show-Limit $(if ($d) { $d.seven_day } else { $null }) $ui.WPct $ui.WCol0 $ui.WCol1 $ui.WFill $ui.WReset $true
  if ($state.MessageBad) {
    $ui.Footer.Text = $state.Message
    $ui.Footer.Foreground = $brushMid
  } elseif ($state.LastOk) {
    $ui.Footer.Text = 'atualizado às ' + $state.LastOk.ToString('HH:mm')
    $ui.Footer.Foreground = $brushFoot
  } else {
    $ui.Footer.Text = $state.Message
    $ui.Footer.Foreground = $brushFoot
  }
  $ui.Footer.ToolTip = $ui.Footer.Text
}

# ---------- consultas ----------
# A cada 3 min (o servidor recusa consultas demais). Nunca mais de 1 a cada 30 s.
function Start-Fetch {
  if ($state.Task) { return }
  $state.LastFetch = Get-Date
  $ui.RefreshIcon.Opacity = 0.35
  $state.Task = [ClaudeUsage.Api]::Fetch()
}

function Complete-Fetch($r) {
  $ui.RefreshIcon.Opacity = 1
  $now = Get-Date
  $state.MessageBad = $true
  if ($r.Error -eq 'nologin') {
    $state.Message = 'Login do Claude Code não encontrado'; $state.NextFetch = $now.AddMinutes(3)
  } elseif ($r.Error -eq 'expired') {
    $state.Message = 'Login expirado: tentando renovar em 5 min'; $state.NextFetch = $now.AddMinutes(5)
  } elseif ($r.Error -eq 'relogin') {
    $state.Message = 'Login inválido: rode "claude" no terminal e entre de novo'; $state.NextFetch = $now.AddMinutes(3)
  } elseif ($r.Error -eq 'network') {
    $state.Message = 'Sem conexão: tentando de novo em 1 min'; $state.NextFetch = $now.AddMinutes(1)
  } elseif ($r.Status -eq 200) {
    try {
      $state.Data = $r.Body | ConvertFrom-Json
      $state.LastOk = $now; $state.MessageBad = $false
    } catch { $state.Message = 'Resposta inesperada da Anthropic' }
    $state.NextFetch = $now.AddMinutes(3)
  } elseif ($r.Status -eq 401 -or $r.Status -eq 403) {
    $state.Message = 'Login recusado: abra o Claude Code'; $state.NextFetch = $now.AddMinutes(3)
  } elseif ($r.Status -eq 429) {
    $state.Message = 'Muitas consultas: nova tentativa às ' + $now.AddMinutes(10).ToString('HH:mm'); $state.NextFetch = $now.AddMinutes(10)
  } else {
    $state.Message = "Erro $($r.Status) da Anthropic: tentando de novo em 3 min"; $state.NextFetch = $now.AddMinutes(3)
  }
  Render
}

$tick = {
  try {
    if ($state.Task) {
      if ($state.Task.IsCompleted) {
        $t = $state.Task; $state.Task = $null
        $r = if ($t.Status -eq 'RanToCompletion') { $t.Result } else { [pscustomobject]@{ Error = 'network'; Status = 0 } }
        Complete-Fetch $r
      }
    } elseif ((Get-Date) -ge $state.NextFetch) {
      Start-Fetch
    }
    if (((Get-Date) - $state.LastRender).TotalSeconds -ge 20 -and $window.WindowState -ne 'Minimized') { Render }
    if ($state.Dirty -and [System.Windows.Input.Mouse]::LeftButton -eq 'Released') { Save-Config }
  } catch {}
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick($tick)

# ---------- tamanho responsivo (igual ao MicWidget) ----------
function Update-Scale {
  if (-not $state.BaseW) { return }
  $aw = $window.ActualWidth  - $state.ChromeW
  $ah = $window.ActualHeight - $state.ChromeH
  $s = [Math]::Max(0.5, [Math]::Min($aw / $state.BaseW, $ah / $state.BaseH))
  $ui.Root.LayoutTransform = New-Object System.Windows.Media.ScaleTransform $s, $s
}

$window.Add_Loaded({
  $state.BaseW  = $ui.Root.ActualWidth
  $state.BaseH  = $ui.Root.ActualHeight
  $w0 = $window.ActualWidth; $h0 = $window.ActualHeight
  $state.ChromeW = $w0 - $state.BaseW
  $state.ChromeH = $h0 - $state.BaseH
  $window.SizeToContent = 'Manual'
  $ui.Root.Width = [double]::NaN
  $window.MinWidth  = [Math]::Round($w0 * 0.7)
  $window.MinHeight = [Math]::Round($h0 * 0.7)
  if ($state.Width -and $state.Height) {
    $window.Width  = [Math]::Max($window.MinWidth,  [double]$state.Width)
    $window.Height = [Math]::Max($window.MinHeight, [double]$state.Height)
  } else {
    $window.Width = $w0; $window.Height = $h0
  }
  Update-Scale
})
$window.Add_SizeChanged({ Update-Scale; $state.Dirty = $true })

# ---------- eventos ----------
$ui.BtnRefresh.Add_Click({ if (((Get-Date) - $state.LastFetch).TotalSeconds -ge 30) { Start-Fetch } })
$ui.BtnClose.Add_Click({ $window.Close() })
$ui.BtnMin.Add_Click({ $window.ShowInTaskbar = $true; $window.WindowState = 'Minimized' })
$window.Add_StateChanged({
  if ($window.WindowState -eq 'Normal') { $window.ShowInTaskbar = $false; Render }
})
$ui.Card.Add_MouseLeftButtonDown({ try { $window.DragMove(); Save-Config } catch {} })

$menu = New-Object System.Windows.Controls.ContextMenu
$miRefresh = New-Object System.Windows.Controls.MenuItem
$miRefresh.Header = 'Atualizar agora'
$miRefresh.Add_Click({ if (((Get-Date) - $state.LastFetch).TotalSeconds -ge 30) { Start-Fetch } })
$miTop = New-Object System.Windows.Controls.MenuItem
$miTop.Header = 'Sempre por cima das janelas'
$miTop.IsCheckable = $true
$miTop.IsChecked = [bool]$state.Topmost
$miTop.Add_Click({ $state.Topmost = $miTop.IsChecked; $window.Topmost = $miTop.IsChecked; Save-Config })
$miStart = New-Object System.Windows.Controls.MenuItem
$miStart.Header = 'Iniciar com o Windows'
$miStart.IsCheckable = $true
$miStart.IsChecked = Test-Path $startupLnk
$miStart.Add_Click({
  try {
    if ($miStart.IsChecked) {
      $ws = New-Object -ComObject WScript.Shell
      $lnk = $ws.CreateShortcut($startupLnk)
      $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
      $lnk.Arguments = "`"$vbsPath`""
      $lnk.WorkingDirectory = $PSScriptRoot
      $lnk.Description = 'ClaudeUsage - uso dos limites do Claude'
      $lnk.Save()
    } elseif (Test-Path $startupLnk) {
      Remove-Item $startupLnk -Force
    }
  } catch {}
})
$miMin = New-Object System.Windows.Controls.MenuItem
$miMin.Header = 'Minimizar'
$miMin.Add_Click({ $window.ShowInTaskbar = $true; $window.WindowState = 'Minimized' })
$miClose = New-Object System.Windows.Controls.MenuItem
$miClose.Header = 'Fechar'
$miClose.Add_Click({ $window.Close() })
[void]$menu.Items.Add($miRefresh)
[void]$menu.Items.Add($miTop)
[void]$menu.Items.Add($miStart)
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
[void]$menu.Items.Add($miMin)
[void]$menu.Items.Add($miClose)
$ui.Card.ContextMenu = $menu

$window.Add_Closing({ $timer.Stop(); Save-Config })

# ---------- início ----------
Render
$timer.Start()
[void]$window.ShowDialog()
$mutex.ReleaseMutex()
