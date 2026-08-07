[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Url,
    [string]$RunnerPath,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolved here, not as a param default: in Windows PowerShell 5.1 a script with
# [CmdletBinding()] evaluates parameter defaults before $PSScriptRoot is populated
# when it is launched with powershell.exe -File, which is exactly how the
# ado-migrate:// protocol handler starts this script. The default binds correctly
# when the script is run from an existing session, so the failure only shows up
# through the protocol.
if ([string]::IsNullOrWhiteSpace($RunnerPath)) {
    $RunnerPath = Join-Path $PSScriptRoot 'ado-project-setup-runner.ps1'
}
$commonModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AdoUtils.Common.psm1'
Import-Module $commonModulePath -Force
$adoRun = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -NonInteractive:$NonInteractive
trap { Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'project-setup-ui'; throw }

if ($Url) {
    $uri = [uri]$Url
    $action = $uri.Host
    if ($action -and $action -notin @('open', 'run')) {
        throw "Unsupported ado-migrate action '$action'."
    }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ADO Migration Launcher" Width="1080" Height="760" MinWidth="940" MinHeight="680"
        WindowStartupLocation="CenterScreen" Background="#f4f5f7">
  <Grid Margin="24">
    <Border Background="White" BorderBrush="#d0d3d8" BorderThickness="1" CornerRadius="8">
      <Grid>
        <!-- Auto, not a fixed height: the phase strip needs 16 + 44 + 8 + label + 14,
             which overflowed the old fixed 88 and clipped the labels. -->
        <Grid.RowDefinitions><RowDefinition Height="48"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <Border Grid.Row="0" Background="#0f2a44" CornerRadius="8,8,0,0">
          <DockPanel Margin="20,0">
            <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock Text="Hso" Foreground="White" FontFamily="Georgia" FontStyle="Italic" FontSize="18" FontWeight="SemiBold"/>
              <TextBlock Text=" | " Foreground="#a9b7c6" FontSize="16" Margin="8,0"/>
              <TextBlock Text="ADO Migration Launcher" Foreground="White" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center"/>
            </StackPanel>
            <TextBlock x:Name="HeaderStatus" DockPanel.Dock="Right" Text="not connected" Foreground="#a9b7c6" FontSize="13" HorizontalAlignment="Right" VerticalAlignment="Center"/>
          </DockPanel>
        </Border>
        <!-- Background="Transparent" on each panel is required: a Panel with a null
             Background is not hit-testable, so clicks would fall through the gaps
             between the circle and its label. -->
        <UniformGrid Grid.Row="1" Columns="4" Margin="40,16,40,14">
          <StackPanel x:Name="PhaseConnectPanel" HorizontalAlignment="Center" Background="Transparent" ToolTip="Go back to source and target details"><Border x:Name="PhaseConnect" Width="44" Height="44" CornerRadius="22" BorderBrush="#0f6cbd" BorderThickness="1"><TextBlock x:Name="PhaseConnectNumber" Text="1" Foreground="#0f6cbd" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock x:Name="PhaseConnectLabel" Text="CONNECT" FontSize="11" FontWeight="SemiBold" Foreground="#1f2933" Margin="0,8,0,0" HorizontalAlignment="Center"/></StackPanel>
          <StackPanel x:Name="PhaseChoosePanel" HorizontalAlignment="Center" Background="Transparent" ToolTip="Choose which steps to run"><Border x:Name="PhaseChoose" Width="44" Height="44" CornerRadius="22" BorderBrush="#e3e5e8" BorderThickness="1"><TextBlock x:Name="PhaseChooseNumber" Text="2" Foreground="#6b7480" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock x:Name="PhaseChooseLabel" Text="CHOOSE STEPS" FontSize="11" FontWeight="SemiBold" Foreground="#6b7480" Margin="0,8,0,0" HorizontalAlignment="Center"/></StackPanel>
          <StackPanel x:Name="PhaseRunPanel" HorizontalAlignment="Center" Background="Transparent" ToolTip="View the current or most recent run"><Border x:Name="PhaseRun" Width="44" Height="44" CornerRadius="22" BorderBrush="#e3e5e8" BorderThickness="1"><TextBlock x:Name="PhaseRunNumber" Text="3" Foreground="#6b7480" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock x:Name="PhaseRunLabel" Text="RUN" FontSize="11" FontWeight="SemiBold" Foreground="#6b7480" Margin="0,8,0,0" HorizontalAlignment="Center"/></StackPanel>
          <StackPanel x:Name="PhaseDonePanel" HorizontalAlignment="Center" Background="Transparent" ToolTip="View the results of the last run"><Border x:Name="PhaseDone" Width="44" Height="44" CornerRadius="22" BorderBrush="#e3e5e8" BorderThickness="1"><TextBlock x:Name="PhaseDoneNumber" Text="4" Foreground="#6b7480" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock x:Name="PhaseDoneLabel" Text="DONE" FontSize="11" FontWeight="SemiBold" Foreground="#6b7480" Margin="0,8,0,0" HorizontalAlignment="Center"/></StackPanel>
        </UniformGrid>
        <Grid Grid.Row="2" Margin="40,18,40,32">
          <Grid x:Name="ConnectScreen">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <StackPanel><TextBlock Text="Connect source and target" FontSize="22" FontWeight="SemiBold"/><TextBlock Text="Enter both project URLs and PATs once. They are held in memory only for this session and are never written to disk." Foreground="#6b7480" FontSize="14" Margin="0,6,0,22"/></StackPanel>
            <Grid Grid.Row="1">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="24"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="20"/><RowDefinition Height="Auto"/><RowDefinition Height="20"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Grid.Column="0"><TextBlock Text="Source project URL" FontSize="13" FontWeight="Medium" Margin="0,0,0,6"/><TextBox x:Name="SourceUrlBox" Height="34" Padding="10,6"/><TextBlock Text="Format: https://dev.azure.com/{org}/{project}" Foreground="#6b7480" FontSize="12" Margin="0,4,0,0"/></StackPanel>
              <StackPanel Grid.Row="0" Grid.Column="2"><TextBlock Text="Target project URL" FontSize="13" FontWeight="Medium" Margin="0,0,0,6"/><TextBox x:Name="TargetUrlBox" Height="34" Padding="10,6"/><TextBlock Text="Target must already exist and use the intended process template." Foreground="#6b7480" FontSize="12" Margin="0,4,0,0"/></StackPanel>
              <StackPanel Grid.Row="2" Grid.Column="0"><TextBlock Text="Source PAT" FontSize="13" FontWeight="Medium" Margin="0,0,0,6"/><PasswordBox x:Name="SourcePatBox" Height="34" Padding="10,6"/><TextBlock Text="Read scopes on Work Items, Queries, Wiki, and Dashboards." Foreground="#6b7480" FontSize="12" Margin="0,4,0,0"/></StackPanel>
              <StackPanel Grid.Row="2" Grid.Column="2"><TextBlock Text="Target PAT" FontSize="13" FontWeight="Medium" Margin="0,0,0,6"/><PasswordBox x:Name="TargetPatBox" Height="34" Padding="10,6"/><TextBlock Text="Read and Write scopes plus Team Settings permissions." Foreground="#6b7480" FontSize="12" Margin="0,4,0,0"/></StackPanel>
              <StackPanel Grid.Row="4" Grid.ColumnSpan="3"><TextBlock Text="Optional target team" FontSize="13" FontWeight="Medium" Margin="0,0,0,6"/><TextBox x:Name="TargetTeamBox" Width="360" HorizontalAlignment="Left" Height="34" Padding="10,6"/><TextBlock Text="Leave blank to infer the project default team." Foreground="#6b7480" FontSize="12" Margin="0,4,0,0"/></StackPanel>
            </Grid>
            <Button x:Name="ContinueButton" Grid.Row="2" Content="Continue" Width="120" Height="34" HorizontalAlignment="Right" Background="#0f6cbd" Foreground="White"/>
          </Grid>
          <Grid x:Name="ChooseScreen" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <StackPanel><TextBlock Text="Choose steps to run" FontSize="22" FontWeight="SemiBold"/><TextBlock Text="Selected steps run in the order shown. You can rerun any step later." Foreground="#6b7480" FontSize="14" Margin="0,6,0,22"/></StackPanel>
            <DataGrid x:Name="StepGrid" Grid.Row="1" AutoGenerateColumns="False" CanUserAddRows="False" HeadersVisibility="Column" BorderBrush="#e3e5e8" BorderThickness="1">
              <DataGrid.Columns><DataGridCheckBoxColumn Header="Run" Binding="{Binding Selected}" Width="60"/><DataGridTextColumn Header="Step" Binding="{Binding Label}" Width="*"/><DataGridTextColumn Header="Details" Binding="{Binding Detail}" Width="2*"/></DataGrid.Columns>
            </DataGrid>
            <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,0,0"><Button x:Name="BackButton" Content="Back" Width="92" Height="34" Margin="0,0,10,0"/><Button x:Name="SelectAllButton" Content="Select all" Width="92" Height="34" Margin="0,0,10,0"/><Button x:Name="RunButton" Content="Run selected steps" Width="160" Height="34" Background="#0f6cbd" Foreground="White"/></StackPanel>
          </Grid>
          <Grid x:Name="RunScreen" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <StackPanel><TextBlock Text="Migration in progress" FontSize="22" FontWeight="SemiBold"/><TextBlock x:Name="RunSubtitle" Text="Do not close this window. Each step writes a target-org_target-project activity log." Foreground="#6b7480" FontSize="14" Margin="0,6,0,22"/></StackPanel>
            <DataGrid x:Name="RunGrid" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column" BorderBrush="#e3e5e8" BorderThickness="1">
              <DataGrid.Columns><DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="110"/><DataGridTextColumn Header="Step" Binding="{Binding Label}" Width="*"/><DataGridTextColumn Header="Message" Binding="{Binding Detail}" Width="2*"/><DataGridTextColumn Header="Log" Binding="{Binding Log}" Width="2*"/></DataGrid.Columns>
            </DataGrid>
            <Button x:Name="CancelRemainingButton" Grid.Row="2" Content="Cancel remaining" Width="140" Height="34" HorizontalAlignment="Right" Margin="0,24,0,0"/>
          </Grid>
          <Grid x:Name="DoneScreen" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="FinalBanner" Padding="12" CornerRadius="6" BorderThickness="1" Background="#eaf7ea" BorderBrush="#c1e3c1"><TextBlock x:Name="FinalMessage" Text="All selected steps completed successfully." FontSize="14" Foreground="#114c11" FontWeight="SemiBold"/></Border>
            <DataGrid x:Name="SummaryGrid" Grid.Row="1" Margin="0,14,0,0" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column" BorderBrush="#e3e5e8" BorderThickness="1">
              <DataGrid.Columns><DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="110"/><DataGridTextColumn Header="Step" Binding="{Binding Label}" Width="*"/><DataGridTextColumn Header="Log" Binding="{Binding Log}" Width="2*"/></DataGrid.Columns>
            </DataGrid>
            <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,0,0"><Button x:Name="OpenLogsButton" Content="Open logs folder" Width="140" Height="34" Margin="0,0,10,0"/><Button x:Name="RerunFailedButton" Content="Rerun failed step" Width="140" Height="34" Margin="0,0,10,0"/><Button x:Name="CloseButton" Content="Close" Width="92" Height="34" Background="#0f6cbd" Foreground="White"/></StackPanel>
          </Grid>
        </Grid>
      </Grid>
    </Border>
  </Grid>
</Window>
"@

$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
function Find-Control { param([string]$Name) $window.FindName($Name) }

$steps = [Collections.ObjectModel.ObservableCollection[object]]::new()
@(
    @($true, 'team-config', '1. Set target team default area (Include sub areas)', 'Prerequisite for area-scoped work items.'),
    @($true, 'iterations', '2. Copy Iteration Paths', 'From source project root to target project root.'),
    @($true, 'areas', '3. Copy Area Paths', 'From source project root to target project root.'),
    @($true, 'work-items', '4. Copy all Work Items', 'All work item types. Source formatting preserved.'),
    @($true, 'queries', '5. Copy Shared Queries (folders + queries)', 'Full Shared Queries hierarchy.'),
    @($false, 'dashboards', '6. Copy Dashboards', 'All dashboards. Widgets rewired to target IDs.'),
    @($false, 'wiki', '7. Copy Wiki (pages, subpages, images)', 'Hierarchy and referenced images preserved.')
) | ForEach-Object {
    $steps.Add([pscustomobject]@{ Selected = $_[0]; Id = $_[1]; Label = $_[2]; Detail = $_[3]; Status = 'Pending'; Log = '' })
}

foreach ($gridName in 'StepGrid','RunGrid','SummaryGrid') { (Find-Control $gridName).ItemsSource = $steps }
$script:RunDirectory = $null
$script:ProgressPath = $null
$script:RunnerProcess = $null
$script:SeenProgressLines = 0

$script:CurrentScreen = 'connect'
$script:HasConnected  = $false
$script:HasRun        = $false

function Test-ScreenReachable {
    <#
        A phase is reachable only once the work it depends on exists. While a run is
        in flight nothing is reachable except the run itself: letting someone back
        into Choose Steps mid-run invites a second runner against the same target.
    #>
    param([ValidateSet('connect','choose','run','done')][string]$Screen)

    $running = $script:RunnerProcess -and -not $script:RunnerProcess.HasExited
    if ($running) { return $Screen -eq 'run' }

    switch ($Screen) {
        'connect' { $true }
        'choose'  { $script:HasConnected }
        'run'     { $script:HasRun }
        'done'    { $script:HasRun }
    }
}

function Set-Screen {
    param([ValidateSet('connect','choose','run','done')][string]$Screen)

    foreach ($name in 'ConnectScreen','ChooseScreen','RunScreen','DoneScreen') { (Find-Control $name).Visibility = 'Collapsed' }
    (Find-Control ("{0}Screen" -f ((Get-Culture).TextInfo.ToTitleCase($Screen)))).Visibility = 'Visible'
    $script:CurrentScreen = $Screen

    $order = @('connect', 'choose', 'run', 'done')
    $activeIndex = $order.IndexOf($Screen)

    for ($i = 0; $i -lt $order.Count; $i++) {
        $name      = @('Connect', 'Choose', 'Run', 'Done')[$i]
        $circle    = Find-Control "Phase$name"
        $number    = Find-Control "Phase${name}Number"
        $label     = Find-Control "Phase${name}Label"
        $panel     = Find-Control "Phase${name}Panel"
        $reachable = Test-ScreenReachable -Screen $order[$i]

        if ($i -eq $activeIndex) {
            $circle.BorderBrush = '#0f6cbd'; $circle.Background = '#e8f2fb'
            $number.Foreground  = '#0f6cbd'; $number.Text = [string]($i + 1)
            $label.Foreground   = '#1f2933'
        } elseif ($i -lt $activeIndex) {
            $circle.BorderBrush = '#00b294'; $circle.Background = '#f1fbf8'
            $number.Foreground  = '#00b294'; $number.Text = [char]0x2713
            $label.Foreground   = '#6b7480'
        } else {
            $circle.BorderBrush = '#e3e5e8'; $circle.Background = 'Transparent'
            $number.Foreground  = '#6b7480'; $number.Text = [string]($i + 1)
            $label.Foreground   = '#6b7480'
        }

        # Only offer a hand cursor where a click will actually go somewhere.
        $panel.Cursor  = if ($reachable -and $i -ne $activeIndex) { 'Hand' } else { 'Arrow' }
        $panel.Opacity = if ($reachable -or $i -eq $activeIndex) { 1.0 } else { 0.45 }
    }
}
function ConvertTo-PlainText { param([Security.SecureString]$Secure) [System.Net.NetworkCredential]::new('', $Secure).Password }

function Test-AdoProjectAccess {
    <#
    .SYNOPSIS
        Confirms one project is reachable with one PAT, before any step runs.

    .DESCRIPTION
        Without this, a wrong source credential is not discovered until the first
        step that reads from the source, which can be several minutes and several
        successful steps into a run.

        A PAT belongs to a single organization. Presented against a different one
        Azure DevOps answers 404, not 401, because it will not confirm the project
        exists. That makes a bare "404" read like a typo in the project name, so it
        is called out explicitly.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectUrl,
        [Parameter(Mandatory)][string]$PlainPat,
        [Parameter(Mandatory)][string]$Label
    )

    try { $endpoint = ConvertFrom-AdoProjectUrl -Url $ProjectUrl -Role Target }
    catch { return [pscustomobject]@{ Ok = $false; Message = "$Label project URL is not valid. $($_.Exception.Message)" } }

    $headers = @{
        Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $PlainPat))
        Accept        = 'application/json'
    }
    $uri = 'https://dev.azure.com/{0}/_apis/projects/{1}?api-version=7.1' -f
        [Uri]::EscapeDataString($endpoint.Org), [Uri]::EscapeDataString($endpoint.Project)

    try {
        Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 20 | Out-Null
        return [pscustomobject]@{ Ok = $true; Message = '' }
    }
    catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        $message = switch ($status) {
            401 { "$Label PAT was rejected. Check that it has not expired and was created in organization '$($endpoint.Org)'." }
            403 { "$Label PAT is valid but lacks permission to read project '$($endpoint.Project)'." }
            404 {
                "$Label project '$($endpoint.Project)' was not found in organization '$($endpoint.Org)'. " +
                "The usual cause is a PAT created in a different organization: a PAT works for one organization only, " +
                "and elsewhere returns 404 rather than a permission error. Confirm the PAT was issued in '$($endpoint.Org)' " +
                "and that the project name matches exactly, including spaces."
            }
            default { "$Label project could not be reached. $($_.Exception.Message)" }
        }
        return [pscustomobject]@{ Ok = $false; Message = $message }
    }
}
function Refresh-Grids { foreach ($gridName in 'StepGrid','RunGrid','SummaryGrid') { (Find-Control $gridName).Items.Refresh() } }

(Find-Control ContinueButton).Add_Click({
    if ([string]::IsNullOrWhiteSpace((Find-Control SourceUrlBox).Text) -or [string]::IsNullOrWhiteSpace((Find-Control TargetUrlBox).Text)) {
        [System.Windows.MessageBox]::Show('Enter both source and target project URLs.', 'ADO Migration Launcher', 'OK', 'Warning') | Out-Null
        return
    }
    if ((Find-Control SourcePatBox).SecurePassword.Length -eq 0 -or (Find-Control TargetPatBox).SecurePassword.Length -eq 0) {
        [System.Windows.MessageBox]::Show('Enter both source and target PATs.', 'ADO Migration Launcher', 'OK', 'Warning') | Out-Null
        return
    }
    # Check both sides now. Two quick reads here are worth far more than discovering
    # a bad credential partway through a run, after earlier steps have already
    # written to the target.
    $button = Find-Control ContinueButton
    $button.IsEnabled = $false
    $originalContent = $button.Content
    $button.Content = 'Checking...'
    try {
        $window.Dispatcher.Invoke([action] {}, 'Render')

        $checks = @(
            @{ Label = 'Source'; Url = (Find-Control SourceUrlBox).Text; Pat = ConvertTo-PlainText (Find-Control SourcePatBox).SecurePassword }
            @{ Label = 'Target'; Url = (Find-Control TargetUrlBox).Text; Pat = ConvertTo-PlainText (Find-Control TargetPatBox).SecurePassword }
        )
        foreach ($check in $checks) {
            $result = Test-AdoProjectAccess -ProjectUrl $check.Url -PlainPat $check.Pat -Label $check.Label
            if (-not $result.Ok) {
                [System.Windows.MessageBox]::Show($result.Message, 'Cannot connect', 'OK', 'Warning') | Out-Null
                return
            }
        }
    }
    finally {
        $button.Content = $originalContent
        $button.IsEnabled = $true
    }

    (Find-Control HeaderStatus).Text = (Find-Control TargetUrlBox).Text
    $script:HasConnected = $true
    Set-Screen choose
})
(Find-Control BackButton).Add_Click({ Set-Screen connect })

# Phase strip navigation. Clicking an unreachable phase explains why rather than
# doing nothing, which would read as the click having missed.
$phaseTargets = @{ PhaseConnectPanel = 'connect'; PhaseChoosePanel = 'choose'; PhaseRunPanel = 'run'; PhaseDonePanel = 'done' }
foreach ($entry in $phaseTargets.GetEnumerator()) {
    $panel  = Find-Control $entry.Key
    $screen = $entry.Value
    $panel.Add_MouseLeftButtonUp({
        if (Test-ScreenReachable -Screen $screen) {
            Set-Screen $screen
            return
        }
        $running = $script:RunnerProcess -and -not $script:RunnerProcess.HasExited
        $reason = if ($running) {
            'A migration is running. Wait for it to finish, or use Cancel remaining, before moving to another step.'
        } elseif ($screen -eq 'choose') {
            'Enter the source and target details first.'
        } else {
            'Run at least one step first.'
        }
        [System.Windows.MessageBox]::Show($reason, 'ADO Migration Launcher', 'OK', 'Information') | Out-Null
    }.GetNewClosure())
}
(Find-Control SelectAllButton).Add_Click({ foreach ($step in $steps) { $step.Selected = $true }; Refresh-Grids })
(Find-Control CloseButton).Add_Click({ $window.Close() })
(Find-Control OpenLogsButton).Add_Click({ if ($script:RunDirectory -and (Test-Path -LiteralPath $script:RunDirectory)) { Start-Process explorer.exe -ArgumentList "`"$script:RunDirectory`"" } })
(Find-Control RerunFailedButton).Add_Click({ foreach ($step in $steps) { $step.Selected = ($step.Status -eq 'Failed') }; Set-Screen choose })
(Find-Control CancelRemainingButton).Add_Click({ if ($script:RunnerProcess -and -not $script:RunnerProcess.HasExited) { $script:RunnerProcess.Kill() } })

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds(1)
function Get-RunnerFailureReason {
    <#
        Pulls the last error the runner recorded so the UI can explain a failure the
        per-step progress feed never saw.
    #>
    param([string]$RunDirectory)

    $fallback = 'The migration runner stopped before it reported any progress. Open the run folder and check the technical logs.'
    if ([string]::IsNullOrWhiteSpace($RunDirectory) -or -not (Test-Path -LiteralPath $RunDirectory)) { return $fallback }

    $errorLog = Get-ChildItem -LiteralPath $RunDirectory -Filter '*error log*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $errorLog) { return $fallback }

    $lastLine = @(Get-Content -LiteralPath $errorLog.FullName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
        Select-Object -Last 1
    if (-not $lastLine) { return $fallback }

    try { $message = ($lastLine | ConvertFrom-Json).message } catch { return $fallback }
    if ([string]::IsNullOrWhiteSpace($message)) { $fallback } else { [string]$message }
}

$timer.Add_Tick({
    if ($script:ProgressPath -and (Test-Path -LiteralPath $script:ProgressPath)) {
        $lines = @(Get-Content -LiteralPath $script:ProgressPath)
        for ($i = $script:SeenProgressLines; $i -lt $lines.Count; $i++) {
            if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
            $event = $lines[$i] | ConvertFrom-Json
            $match = @($steps | Where-Object { $_.Id -eq $event.step } | Select-Object -First 1)
            if ($match.Count) {
                $match[0].Status = (Get-Culture).TextInfo.ToTitleCase([string]$event.status)
                $match[0].Detail = [string]$event.message
                $match[0].Log = [string]$event.logPath
            }
        }
        $script:SeenProgressLines = $lines.Count
        Refresh-Grids
    }
    if ($script:RunnerProcess -and $script:RunnerProcess.HasExited) {
        $timer.Stop()
        $exitCode = $script:RunnerProcess.ExitCode

        # The runner can die before it reports progress for any step, for example on
        # a bad argument or a credential failure. Those steps never ran, so leaving
        # them on Pending reads as "still working" on a finished run. Mark them
        # failed and carry the runner's own error message across.
        $reason = ''
        if ($exitCode -ne 0) {
            $reason = Get-RunnerFailureReason -RunDirectory $script:RunDirectory
            foreach ($step in @($steps | Where-Object { $_.Selected -and $_.Status -in @('Pending', 'Running') })) {
                $step.Status = 'Failed'
                if ([string]::IsNullOrWhiteSpace($step.Detail)) { $step.Detail = $reason }
            }
            Refresh-Grids
        }

        $failedCount = @($steps | Where-Object { $_.Selected -and $_.Status -eq 'Failed' }).Count
        if ($failedCount -gt 0 -or $exitCode -ne 0) {
            (Find-Control FinalBanner).Background = '#fbeeef'
            (Find-Control FinalBanner).BorderBrush = '#ecc5c8'
            (Find-Control FinalMessage).Foreground = '#6a151a'
            $plural = if ($failedCount -eq 1) { 'step' } else { 'steps' }
            $text = "$failedCount selected $plural failed. Review the log and rerun only the failed step."
            if ($reason) { $text = "$text`n`n$reason" }
            (Find-Control FinalMessage).Text = $text
        } else {
            (Find-Control FinalMessage).Text = 'All selected steps completed successfully.'
        }
        Set-Screen done
    }
})

(Find-Control RunButton).Add_Click({
    $selected = @($steps | Where-Object { $_.Selected })
    if (-not $selected.Count) {
        [System.Windows.MessageBox]::Show('Select at least one step to run.', 'ADO Migration Launcher', 'OK', 'Warning') | Out-Null
        return
    }
    # Clear only what is being rerun. A step that already succeeded in an earlier run
    # keeps its status and log link, so returning through the phase strip to run more
    # steps builds up a complete picture instead of blanking previous results.
    foreach ($step in $steps) {
        if ($step.Selected) { $step.Status = 'Pending'; $step.Log = '' }
        elseif ([string]::IsNullOrWhiteSpace([string]$step.Status) -or $step.Status -eq 'Pending') { $step.Status = 'Skipped' }
    }
    Refresh-Grids
    $script:HasRun = $true
    $target = ConvertFrom-AdoProjectUrl -Url (Find-Control TargetUrlBox).Text -Role Target
    $targetPart = ('{0}_{1}' -f $target.Org, $target.Project) -replace '[\\/:*?"<>|]', '_'
    $script:RunDirectory = Join-Path (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AdoMigrationLogs') (Join-Path $targetPart (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [IO.Directory]::CreateDirectory($script:RunDirectory) | Out-Null
    $script:ProgressPath = Join-Path $script:RunDirectory 'progress.jsonl'
    $script:SeenProgressLines = 0
    $env:ADO_SOURCE_PAT = ConvertTo-PlainText (Find-Control SourcePatBox).SecurePassword
    $env:ADO_TARGET_PAT = ConvertTo-PlainText (Find-Control TargetPatBox).SecurePassword
    $argList = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$RunnerPath`"",
        '-SourceProjectUrl',"`"$((Find-Control SourceUrlBox).Text)`"",
        '-TargetProjectUrl',"`"$((Find-Control TargetUrlBox).Text)`"",
        '-Steps',($selected.Id -join ','),
        '-RunRoot',"`"$script:RunDirectory`"",
        '-ProgressPath',"`"$script:ProgressPath`"",
        '-NonInteractive'
    )
    if (-not [string]::IsNullOrWhiteSpace((Find-Control TargetTeamBox).Text)) { $argList += @('-TargetTeam', "`"$((Find-Control TargetTeamBox).Text)`"") }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = $argList -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:RunnerProcess = [Diagnostics.Process]::Start($psi)
    $env:ADO_SOURCE_PAT = $null
    $env:ADO_TARGET_PAT = $null
    (Find-Control RunSubtitle).Text = "Do not close this window. Logs are written under $script:RunDirectory"
    Set-Screen run
    $timer.Start()
})

Set-Screen connect
$null = $window.ShowDialog()
Complete-AdoScriptRun -Outcome succeeded -ErrorRecord $null -Operation 'project-setup-ui' -Message 'UI session closed.'
