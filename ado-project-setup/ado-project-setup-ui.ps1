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
        WindowStartupLocation="CenterScreen" Background="#F2F5F8"
        FontFamily="Segoe UI Variable Text, Segoe UI">
  <Window.Resources>
    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="#1AA6C9"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="8" BorderThickness="0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="border" Property="Background" Value="#0E86A8"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="border" Property="Background" Value="#a0a0a0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SecondaryButton" TargetType="Button">
      <Setter Property="Background" Value="#F2F5F8"/>
      <Setter Property="Foreground" Value="#15232F"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="#E3E8EC"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="FontWeight" Value="Medium"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="border" Property="Background" Value="#E7ECEF"/>
                <Setter TargetName="border" Property="BorderBrush" Value="#1AA6C9"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="BorderBrush" Value="#E3E8EC"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#15232F"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Style.Triggers>
        <Trigger Property="IsFocused" Value="True">
          <Setter Property="BorderBrush" Value="#1AA6C9"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Background" Value="#F2F5F8"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="BorderBrush" Value="#E3E8EC"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#15232F"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Style.Triggers>
        <Trigger Property="IsFocused" Value="True">
          <Setter Property="BorderBrush" Value="#1AA6C9"/>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <Grid Margin="24">
    <Border Background="White" BorderBrush="#E3E8EC" BorderThickness="1" CornerRadius="14">
      <Border.Effect>
        <DropShadowEffect Color="#0A2E4D" Opacity="0.16" BlurRadius="28" ShadowDepth="6" Direction="270"/>
      </Border.Effect>
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="68"/><RowDefinition Height="1"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <Border Grid.Row="0" Background="#072238" CornerRadius="14,14,0,0">
          <DockPanel Margin="24,0">
            <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock Text="HSO" Foreground="White" FontFamily="Georgia" FontStyle="Italic" FontSize="18" FontWeight="SemiBold"/>
              <TextBlock Text=" | " Foreground="#5C7A90" FontSize="16" Margin="8,0"/>
              <TextBlock Text="ADO Migration Launcher" Foreground="White" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel x:Name="HeaderStatus" DockPanel.Dock="Right" HorizontalAlignment="Right" VerticalAlignment="Center" Visibility="Collapsed">
              <TextBlock x:Name="HeaderSourceText" Text="Source: not connected" Foreground="#BFE7F2" FontSize="11" HorizontalAlignment="Right" Margin="0,0,0,2"/>
              <TextBlock x:Name="HeaderTargetText" Text="Target: not connected" Foreground="#BFE7F2" FontSize="11" HorizontalAlignment="Right"/>
            </StackPanel>
          </DockPanel>
        </Border>
        <Border Grid.Row="1" Background="#12405C" Height="1"/>
        <UniformGrid Grid.Row="2" Columns="4" Margin="40,16,40,14">
          <StackPanel x:Name="PhaseConnectPanel" HorizontalAlignment="Center" Background="Transparent" ToolTip="Go back to source and target details"><Border x:Name="PhaseConnect" Width="48" Height="48" CornerRadius="24" BorderBrush="#1AA6C9" BorderThickness="1"><TextBlock x:Name="PhaseConnectNumber" Text="1" Foreground="#1AA6C9" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock x:Name="PhaseConnectLabel" Text="CONNECT" FontSize="11" FontWeight="SemiBold" Foreground="#15232F" Margin="0,8,0,0" HorizontalAlignment="Center"/></StackPanel>
          <StackPanel x:Name="PhaseChoosePanel" HorizontalAlignment="Center" Background="Transparent" ToolTip="Choose which steps to run"><Border x:Name="PhaseChoose" Width="48" Height="48" CornerRadius="24" BorderBrush="#E3E8EC" BorderThickness="1"><TextBlock x:Name="PhaseChooseNumber" Text="2" Foreground="#85949F" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock x:Name="PhaseChooseLabel" Text="CHOOSE STEPS" FontSize="11" FontWeight="SemiBold" Foreground="#85949F" Margin="0,8,0,0" HorizontalAlignment="Center"/></StackPanel>
          <StackPanel x:Name="PhaseRunPanel" HorizontalAlignment="Center" Background="Transparent" ToolTip="View the current or most recent run"><Border x:Name="PhaseRun" Width="48" Height="48" CornerRadius="24" BorderBrush="#E3E8EC" BorderThickness="1"><TextBlock x:Name="PhaseRunNumber" Text="3" Foreground="#85949F" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock x:Name="PhaseRunLabel" Text="RUN" FontSize="11" FontWeight="SemiBold" Foreground="#85949F" Margin="0,8,0,0" HorizontalAlignment="Center"/></StackPanel>
          <StackPanel x:Name="PhaseDonePanel" HorizontalAlignment="Center" Background="Transparent" ToolTip="View the results of the last run"><Border x:Name="PhaseDone" Width="48" Height="48" CornerRadius="24" BorderBrush="#E3E8EC" BorderThickness="1"><TextBlock x:Name="PhaseDoneNumber" Text="4" Foreground="#85949F" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock x:Name="PhaseDoneLabel" Text="DONE" FontSize="11" FontWeight="SemiBold" Foreground="#85949F" Margin="0,8,0,0" HorizontalAlignment="Center"/></StackPanel>
        </UniformGrid>
        <Grid Grid.Row="3" Margin="24,18,24,24">
          <Grid x:Name="ConnectScreen">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <StackPanel><TextBlock Text="Connect source and target" FontSize="23" FontWeight="SemiBold" FontFamily="Segoe UI Variable Display, Segoe UI Semibold, Segoe UI"/><TextBlock Text="Enter both project URLs and PATs once. They are held in memory only for this session and are never written to disk." Foreground="#85949F" FontSize="14" Margin="0,6,0,22"/></StackPanel>
            <Grid Grid.Row="1">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="24"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="20"/><RowDefinition Height="Auto"/><RowDefinition Height="20"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Grid.Column="0"><TextBlock Text="Source project URL" FontSize="13" FontWeight="Medium" Margin="0,0,0,6"/><TextBox x:Name="SourceUrlBox" Height="34" Padding="10,6"/><TextBlock Text="Format: https://dev.azure.com/{org}/{project}" Foreground="#85949F" FontSize="12" Margin="0,4,0,0"/></StackPanel>
              <StackPanel Grid.Row="0" Grid.Column="2"><TextBlock Text="Target project URL" FontSize="13" FontWeight="Medium" Margin="0,0,0,6"/><TextBox x:Name="TargetUrlBox" Height="34" Padding="10,6"/><TextBlock Text="Target must already exist unless Step 0's mode below creates it." Foreground="#85949F" FontSize="12" Margin="0,4,0,0"/></StackPanel>
              <StackPanel Grid.Row="2" Grid.Column="0"><TextBlock Text="Source PAT" FontSize="13" FontWeight="Medium" Margin="0,0,0,6"/><PasswordBox x:Name="SourcePatBox" Height="34" Padding="10,6"/><TextBlock Text="Read scopes on Work Items, Process, Queries, Wiki, and Dashboards." Foreground="#85949F" FontSize="12" Margin="0,4,0,0"/></StackPanel>
              <StackPanel Grid.Row="2" Grid.Column="2"><TextBlock Text="Target PAT" FontSize="13" FontWeight="Medium" Margin="0,0,0,6"/><PasswordBox x:Name="TargetPatBox" Height="34" Padding="10,6"/><TextBlock Text="Read and Write scopes plus Process and Team Settings permissions." Foreground="#85949F" FontSize="12" Margin="0,4,0,0"/></StackPanel>
              <StackPanel Grid.Row="4" Grid.Column="0"><TextBlock Text="Process name (optional for Step 0)" FontSize="13" FontWeight="Medium" Margin="0,0,0,6"/><TextBox x:Name="ProcessNameBox" Height="34" Padding="10,6"/><TextBlock Text="Required only if migrating the process template." Foreground="#85949F" FontSize="12" Margin="0,4,0,0"/></StackPanel>
              <StackPanel Grid.Row="4" Grid.Column="2">
                <TextBlock Text="Process migration mode (Step 0)" FontSize="13" FontWeight="Medium" Margin="0,0,0,6"/>
                <RadioButton x:Name="ModeFullAutoRadio" GroupName="ProcessMode" Content="Full automation - create the process and the target project" IsChecked="True" Margin="0,0,0,6" FontSize="12"/>
                <RadioButton x:Name="ModeAssistedRadio" GroupName="ProcessMode" Content="Process now, project later - I'll get the project created or switched myself" Margin="0,0,0,6" FontSize="12"/>
                <RadioButton x:Name="ModeExportRadio" GroupName="ProcessMode" Content="Export process only - no changes in the target org, hand off a file" Margin="0,0,0,6" FontSize="12"/>
                <TextBlock Text="Applies only if Step 0 is selected on the next screen." Foreground="#85949F" FontSize="12"/>
              </StackPanel>
            </Grid>
            <Button x:Name="ContinueButton" Grid.Row="2" Content="Continue" Width="120" Height="36" HorizontalAlignment="Right" Style="{StaticResource PrimaryButton}"/>
          </Grid>
          <Grid x:Name="ChooseScreen" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <StackPanel><TextBlock Text="Choose steps to run" FontSize="23" FontWeight="SemiBold" FontFamily="Segoe UI Variable Display, Segoe UI Semibold, Segoe UI"/><TextBlock Text="Selected steps run in the order shown. You can rerun any step later." Foreground="#85949F" FontSize="14" Margin="0,6,0,22"/></StackPanel>
            <DataGrid x:Name="StepGrid" Grid.Row="1" AutoGenerateColumns="False" CanUserAddRows="False" HeadersVisibility="Column" BorderBrush="#E3E8EC" BorderThickness="1" RowHeight="36" AlternatingRowBackground="#f9fafb" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#E7ECEF">
              <DataGrid.Columns><DataGridCheckBoxColumn Header="Run" Binding="{Binding Selected}" Width="60"/><DataGridTextColumn Header="Step" Binding="{Binding Label}" Width="*"/><DataGridTextColumn Header="Details" Binding="{Binding Detail}" Width="2*"/></DataGrid.Columns>
            </DataGrid>
            <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0"><Button x:Name="BackButton" Content="Back" Width="92" Height="36" Margin="0,0,10,0" Style="{StaticResource SecondaryButton}"/><Button x:Name="SelectAllButton" Content="Select all" Width="92" Height="36" Margin="0,0,10,0" Style="{StaticResource SecondaryButton}"/><Button x:Name="RunButton" Content="Run selected steps" Width="160" Height="36" Style="{StaticResource PrimaryButton}"/></StackPanel>
          </Grid>
          <Grid x:Name="RunScreen" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <StackPanel><TextBlock Text="Migration in progress" FontSize="23" FontWeight="SemiBold" FontFamily="Segoe UI Variable Display, Segoe UI Semibold, Segoe UI"/><TextBlock x:Name="RunSubtitle" Text="Do not close this window. Each step writes a target-org_target-project activity log." Foreground="#85949F" FontSize="14" Margin="0,6,0,22"/></StackPanel>
            <DataGrid x:Name="RunGrid" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column" BorderBrush="#E3E8EC" BorderThickness="1" RowHeight="36" AlternatingRowBackground="#f9fafb" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#E7ECEF">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="110"/>
                <DataGridTextColumn Header="Step" Binding="{Binding Label}" Width="*"/>
                <DataGridTextColumn Header="Message" Binding="{Binding Detail}" Width="2*"/>
                <DataGridTemplateColumn Header="Log" Width="60">
                  <DataGridTemplateColumn.CellTemplate>
                    <DataTemplate>
                      <Ellipse Width="16" Height="16" Stroke="{Binding LogStroke}" StrokeThickness="2" Fill="{Binding LogFill}" Cursor="{Binding LogCursor}" ToolTip="{Binding Log}" HorizontalAlignment="Center"/>
                    </DataTemplate>
                  </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
              </DataGrid.Columns>
            </DataGrid>
            <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0"><Button x:Name="BackToChooseFromRunButton" Content="&lt; Choose Steps" Width="140" Height="36" Margin="0,0,10,0" Style="{StaticResource SecondaryButton}"/><Button x:Name="CancelRemainingButton" Content="Cancel remaining" Width="140" Height="36" Style="{StaticResource SecondaryButton}"/></StackPanel>
          </Grid>
          <Grid x:Name="DoneScreen" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="FinalBanner" Padding="12" CornerRadius="6" BorderThickness="1" Background="#eaf7ea" BorderBrush="#c1e3c1"><TextBlock x:Name="FinalMessage" Text="All selected steps completed successfully." FontSize="14" Foreground="#114c11" FontWeight="SemiBold"/></Border>
            <DataGrid x:Name="SummaryGrid" Grid.Row="1" Margin="0,14,0,0" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column" BorderBrush="#E3E8EC" BorderThickness="1" RowHeight="36" AlternatingRowBackground="#f9fafb" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#E7ECEF">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="110"/>
                <DataGridTextColumn Header="Step" Binding="{Binding Label}" Width="*"/>
                <DataGridTemplateColumn Header="Log" Width="60">
                  <DataGridTemplateColumn.CellTemplate>
                    <DataTemplate>
                      <Ellipse Width="16" Height="16" Stroke="{Binding LogStroke}" StrokeThickness="2" Fill="{Binding LogFill}" Cursor="{Binding LogCursor}" ToolTip="{Binding Log}" HorizontalAlignment="Center"/>
                    </DataTemplate>
                  </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
              </DataGrid.Columns>
            </DataGrid>
            <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0"><Button x:Name="BackToChooseFromDoneButton" Content="&lt; Choose Steps" Width="140" Height="36" Margin="0,0,10,0" Style="{StaticResource SecondaryButton}"/><Button x:Name="OpenLogsButton" Content="Open logs folder" Width="140" Height="36" Margin="0,0,10,0" Style="{StaticResource SecondaryButton}"/><Button x:Name="RerunFailedButton" Content="Rerun failed step" Width="140" Height="36" Margin="0,0,10,0" Style="{StaticResource SecondaryButton}"/><Button x:Name="CloseButton" Content="Close" Width="92" Height="36" Style="{StaticResource PrimaryButton}"/></StackPanel>
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
    @($false, 'process', '0. Migrate Process Template (WITs, fields, picklists, rules)', 'Optional prerequisite if target uses a different process. Mode selected on the previous screen controls what happens: full automation creates the project too; assisted stops for a manual project step; export-only writes a handoff file and makes no target changes.'),
    @($true, 'team-config', '1. Set target team default area (Include sub areas)', 'Prerequisite for area-scoped work items.'),
    @($true, 'iterations', '2. Copy Iteration Paths', 'From source project root to target project root.'),
    @($true, 'areas', '3. Copy Area Paths', 'From source project root to target project root.'),
    @($true, 'work-items', '4. Copy all Work Items', 'All work item types. Source formatting preserved.'),
    @($true, 'queries', '5. Copy Shared Queries (folders + queries)', 'Full Shared Queries hierarchy.'),
    @($false, 'dashboards', '6. Copy Dashboards', 'All dashboards. Widgets rewired to target IDs.'),
    @($false, 'wiki', '7. Copy Wiki (pages, subpages, images)', 'Hierarchy and referenced images preserved.')
) | ForEach-Object {
    $steps.Add([pscustomobject]@{ 
        Selected = $_[0]; Id = $_[1]; Label = $_[2]; Detail = $_[3]; 
        Status = 'Pending'; Log = ''; 
        LogFill = 'Transparent'; LogStroke = '#E3E8EC'; LogCursor = 'Arrow'
    })
}

foreach ($gridName in 'StepGrid','RunGrid','SummaryGrid') { (Find-Control $gridName).ItemsSource = $steps }

# Add click handlers for log indicators in Run and Summary grids
foreach ($gridName in @('RunGrid', 'SummaryGrid')) {
    $grid = Find-Control $gridName
    $grid.Add_PreviewMouseLeftButtonUp({
        param($sender, $e)
        $element = $e.OriginalSource
        if ($element -is [System.Windows.Shapes.Ellipse]) {
            $dataItem = $element.DataContext
            if ($dataItem -and -not [string]::IsNullOrWhiteSpace($dataItem.Log)) {
                if (Test-Path -LiteralPath $dataItem.Log) {
                    Start-Process notepad.exe -ArgumentList "`"$($dataItem.Log)`""
                }
            }
        }
    })
}

$script:RunDirectory = $null
$script:ProgressPath = $null
$script:RunnerProcess = $null
$script:SeenProgressLines = 0
# Set when the last run ended with Step 0 in ExportOnly mode: there is nothing to
# resume (no target-org calls were made), so "Rerun"/"Continue" semantics do not
# apply -- the coordinator starts an entirely fresh run instead.
$script:LastRunHadExport = $false

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
            # Current screen - show as active (blue) unless it's the Done screen
            if ($Screen -eq 'done' -and $i -eq 3) {
                # Done screen should show as complete (green checkmark) not active
                $circle.BorderBrush = '#00b294'; $circle.Background = '#f1fbf8'
                $number.Foreground  = '#00b294'; $number.Text = [char]0x2713
                $label.Foreground   = '#15232F'
            } else {
                $circle.BorderBrush = '#1AA6C9'; $circle.Background = '#DDF2F7'
                $number.Foreground  = '#1AA6C9'; $number.Text = [string]($i + 1)
                $label.Foreground   = '#15232F'
            }
        } elseif ($i -lt $activeIndex) {
            $circle.BorderBrush = '#00b294'; $circle.Background = '#f1fbf8'
            $number.Foreground  = '#00b294'; $number.Text = [char]0x2713
            $label.Foreground   = '#85949F'
        } else {
            $circle.BorderBrush = '#E3E8EC'; $circle.Background = 'Transparent'
            $number.Foreground  = '#85949F'; $number.Text = [string]($i + 1)
            $label.Foreground   = '#85949F'
        }

        # Only offer a hand cursor where a click will actually go somewhere.
        $panel.Cursor  = if ($reachable -and $i -ne $activeIndex) { 'Hand' } else { 'Arrow' }
        $panel.Opacity = if ($reachable -or $i -eq $activeIndex) { 1.0 } else { 0.45 }
    }
}
function Reset-ConnectScreen {
    <#
        Used after an ExportOnly run: that run made no target-org calls and has
        nothing to resume, so "Start New Run" clears everything and returns to a
        blank Connect screen rather than re-selecting steps on Choose.
    #>
    (Find-Control SourceUrlBox).Text = ''
    (Find-Control TargetUrlBox).Text = ''
    (Find-Control SourcePatBox).Clear()
    (Find-Control TargetPatBox).Clear()
    (Find-Control ProcessNameBox).Text = ''
    (Find-Control ModeAssistedRadio).IsChecked = $true
    (Find-Control HeaderStatus).Visibility = 'Collapsed'
    $script:HasConnected = $false
    $script:HasRun = $false
    $script:RunDirectory = $null
    $script:ProgressPath = $null
    $script:SeenProgressLines = 0
    $script:LastRunHadExport = $false
    foreach ($step in $steps) {
        $step.Status = 'Pending'; $step.Log = ''; $step.LogFill = 'Transparent'; $step.LogStroke = '#E3E8EC'; $step.LogCursor = 'Arrow'
    }
    Refresh-Grids
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

    try {
        $headers = @{
            Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $PlainPat))
            Accept        = 'application/json'
        }
        $uri = 'https://dev.azure.com/{0}/_apis/projects/{1}?api-version=7.1' -f
            [Uri]::EscapeDataString($endpoint.Org), [Uri]::EscapeDataString($endpoint.Project)

        Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 20 | Out-Null
        return [pscustomobject]@{ Ok = $true; Message = ''; Status = 200; Org = $endpoint.Org; Project = $endpoint.Project }
    }
    catch {
        # Capture before the switch: inside a switch's script blocks, $_ is
        # rebound to the value being matched (here, $status) -- not the outer
        # catch's error record. Referencing $_.Exception inside a switch case
        # was silently grabbing $status.Exception, which doesn't exist and
        # throws its own StrictMode error, masking whatever the real problem was.
        $errorRecord = $_
        $status = $null
        try { $status = [int]$errorRecord.Exception.Response.StatusCode } catch { }
        $message = switch ($status) {
            401 { "$Label PAT was rejected. Check that it has not expired and was created in organization '$($endpoint.Org)'." }
            403 { "$Label PAT is valid but lacks permission to read project '$($endpoint.Project)'." }
            404 {
                "$Label project '$($endpoint.Project)' was not found in organization '$($endpoint.Org)'. " +
                "The usual cause is a PAT created in a different organization: a PAT works for one organization only, " +
                "and elsewhere returns 404 rather than a permission error. Confirm the PAT was issued in '$($endpoint.Org)' " +
                "and that the project name matches exactly, including spaces."
            }
            default { "$Label project could not be reached. $($errorRecord.Exception.Message)" }
        }
        return [pscustomobject]@{ Ok = $false; Message = $message; Status = $status; Org = $endpoint.Org; Project = $endpoint.Project }
    }
}

function Test-AdoOrgAccess {
    <#
    .SYNOPSIS
        Confirms a PAT is valid in an organization, without requiring any
        specific project to exist yet.

    .DESCRIPTION
        Used as a fallback when Test-AdoProjectAccess 404s and Step 0 is in
        play (a process name was supplied): the target project may
        legitimately not exist yet -- FullAuto creates it, AssistedManual can
        stop and ask a person to create it, and ExportOnly never touches the
        target org at all. Lists (at most one) project in the org rather than
        reading a specific one, so it confirms "this PAT works in this
        organization" without needing the target project to be there.

        Deliberately NOT _apis/ConnectionData: that endpoint isn't part of the
        documented, versioned REST surface and rejects an api-version query
        string with HTTP 400. Projects - List is a stable, documented
        endpoint, and "Project/team metadata Read" is already a baseline
        target PAT scope per this launcher's README, so this adds no new
        permission requirement.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectUrl,
        [Parameter(Mandatory)][string]$PlainPat,
        [Parameter(Mandatory)][string]$Label
    )

    try { $endpoint = ConvertFrom-AdoProjectUrl -Url $ProjectUrl -Role Target }
    catch { return [pscustomobject]@{ Ok = $false; Message = "$Label project URL is not valid. $($_.Exception.Message)" } }

    try {
        $headers = @{
            Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $PlainPat))
            Accept        = 'application/json'
        }
        $uri = 'https://dev.azure.com/{0}/_apis/projects?$top=1&api-version=7.1' -f [Uri]::EscapeDataString($endpoint.Org)

        Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 20 | Out-Null
        return [pscustomobject]@{ Ok = $true; Message = ''; Org = $endpoint.Org; Project = $endpoint.Project }
    }
    catch {
        # See the matching comment in Test-AdoProjectAccess: $_ inside a switch
        # case is rebound to the switch subject, not the outer catch's error
        # record, so it must be captured before the switch.
        $errorRecord = $_
        $status = $null
        try { $status = [int]$errorRecord.Exception.Response.StatusCode } catch { }
        $message = switch ($status) {
            401 { "$Label PAT was rejected. Check that it has not expired and was created in organization '$($endpoint.Org)'." }
            403 { "$Label PAT is valid but lacks permission to connect to organization '$($endpoint.Org)'." }
            default { "$Label organization '$($endpoint.Org)' could not be reached. $($errorRecord.Exception.Message)" }
        }
        return [pscustomobject]@{ Ok = $false; Message = $message; Org = $endpoint.Org; Project = $endpoint.Project }
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

        # A process name means Step 0 may run, and two of its three modes
        # (FullAuto, and AssistedManual's project-missing sub-case) expect the
        # target project not to exist yet. AllowMissingProject lets that 404
        # through instead of hard-blocking Connect.
        $processNameProvided = -not [string]::IsNullOrWhiteSpace((Find-Control ProcessNameBox).Text)
        $checks = @(
            @{ Label = 'Source'; Url = (Find-Control SourceUrlBox).Text; Pat = ConvertTo-PlainText (Find-Control SourcePatBox).SecurePassword; AllowMissingProject = $false }
            @{ Label = 'Target'; Url = (Find-Control TargetUrlBox).Text; Pat = ConvertTo-PlainText (Find-Control TargetPatBox).SecurePassword; AllowMissingProject = $processNameProvided }
        )
        foreach ($check in $checks) {
            $result = Test-AdoProjectAccess -ProjectUrl $check.Url -PlainPat $check.Pat -Label $check.Label
            if (-not $result.Ok) {
                if ($check.AllowMissingProject -and $result.Status -eq 404) {
                    $orgResult = Test-AdoOrgAccess -ProjectUrl $check.Url -PlainPat $check.Pat -Label $check.Label
                    if (-not $orgResult.Ok) {
                        [System.Windows.MessageBox]::Show($orgResult.Message, 'Cannot connect', 'OK', 'Warning') | Out-Null
                        return
                    }
                    [System.Windows.MessageBox]::Show(
                        "$($check.Label) project '$($orgResult.Project)' was not found yet in organization '$($orgResult.Org)' -- that's expected if Step 0 will create it, or if you'll create/switch it manually. Continuing.",
                        'ADO Migration Launcher', 'OK', 'Information') | Out-Null
                    continue
                }
                [System.Windows.MessageBox]::Show($result.Message, 'Cannot connect', 'OK', 'Warning') | Out-Null
                return
            }
        }

        # Update header with source and target org/project
        $source = ConvertFrom-AdoProjectUrl -Url (Find-Control SourceUrlBox).Text -Role Source
        $target = ConvertFrom-AdoProjectUrl -Url (Find-Control TargetUrlBox).Text -Role Target
        (Find-Control HeaderSourceText).Text = "Source: $($source.Org) - $($source.Project)"
        (Find-Control HeaderTargetText).Text = "Target: $($target.Org) - $($target.Project)"
        (Find-Control HeaderStatus).Visibility = 'Visible'
        $script:HasConnected = $true
        Set-Screen choose
    }
    catch {
        # This handler used to have no catch, only a finally -- an unexpected
        # exception here (a bad URL format, an unreachable host, anything not
        # already turned into a friendly message above) would propagate out of
        # the event handler and, since the launcher normally runs with
        # -WindowStyle Hidden, silently kill the whole process: the window
        # just vanishes with no error shown at all. Catching here converts
        # that into a visible, actionable message instead.
        [System.Windows.MessageBox]::Show("An unexpected error occurred while connecting: $($_.Exception.Message)", 'ADO Migration Launcher', 'OK', 'Error') | Out-Null
    }
    finally {
        $button.Content = $originalContent
        $button.IsEnabled = $true
    }
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
(Find-Control RerunFailedButton).Add_Click({
    if ($script:LastRunHadExport) {
        Reset-ConnectScreen
        Set-Screen connect
        return
    }
    foreach ($step in $steps) { $step.Selected = ($step.Status -in @('Failed', 'Degraded')) }
    Set-Screen choose
})
(Find-Control CancelRemainingButton).Add_Click({ if ($script:RunnerProcess -and -not $script:RunnerProcess.HasExited) { $script:RunnerProcess.Kill() } })
(Find-Control BackToChooseFromRunButton).Add_Click({ if (-not ($script:RunnerProcess -and -not $script:RunnerProcess.HasExited)) { Set-Screen choose } })
(Find-Control BackToChooseFromDoneButton).Add_Click({ Set-Screen choose })

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds(1)
function Get-RunnerFailureReason {
    <#
        Pulls the last error the runner recorded so the UI can explain a failure the
        per-step progress feed never saw. Tries the runner's own JSONL error log
        first, then falls back to the raw console (stdout/stderr) capture -- the
        JSONL log can legitimately be empty if the runner process died before, or
        without, successfully logging through AdoUtils.Common (see the comment on
        Write-RunnerCrashLog in ado-project-setup-runner.ps1), so the console
        capture is the last line of defense for explaining a crash.
    #>
    param([string]$RunDirectory)

    $fallback = 'The migration runner stopped before it reported any progress. Open the run folder and check the technical logs.'
    if ([string]::IsNullOrWhiteSpace($RunDirectory) -or -not (Test-Path -LiteralPath $RunDirectory)) { return $fallback }

    $errorLog = Get-ChildItem -LiteralPath $RunDirectory -Filter '*error log*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($errorLog) {
        $lastLine = @(Get-Content -LiteralPath $errorLog.FullName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
            Select-Object -Last 1
        if ($lastLine) {
            try {
                $message = ($lastLine | ConvertFrom-Json).message
                if (-not [string]::IsNullOrWhiteSpace($message)) { return [string]$message }
            } catch { }
        }
    }

    $consoleLog = Join-Path $RunDirectory 'runner-console.log'
    if (Test-Path -LiteralPath $consoleLog) {
        $consoleLines = @(Get-Content -LiteralPath $consoleLog | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
            Select-Object -Last 15
        if ($consoleLines.Count) { return ($consoleLines -join [Environment]::NewLine) }
    }

    $fallback
}

function Update-LogIndicators {
    # Update RAG indicator properties on step objects (data-bound to Ellipse)
    foreach ($step in $steps) {
        $hasLog = -not [string]::IsNullOrWhiteSpace($step.Log)
        switch ($step.Status) {
            'Pending'   { $step.LogFill = 'Transparent'; $step.LogStroke = '#E3E8EC'; $step.LogCursor = 'Arrow' }
            'Skipped'   { $step.LogFill = 'Transparent'; $step.LogStroke = '#E3E8EC'; $step.LogCursor = 'Arrow' }
            'Running'   { $step.LogFill = '#90EE90'; $step.LogStroke = '#00b294'; $step.LogCursor = if ($hasLog) { 'Hand' } else { 'Arrow' } }
            'Succeeded' { $step.LogFill = '#00b294'; $step.LogStroke = '#00b294'; $step.LogCursor = if ($hasLog) { 'Hand' } else { 'Arrow' } }
            'Degraded'  { $step.LogFill = '#f59e0b'; $step.LogStroke = '#f59e0b'; $step.LogCursor = if ($hasLog) { 'Hand' } else { 'Arrow' } }
            'Exported'  { $step.LogFill = '#3b82f6'; $step.LogStroke = '#3b82f6'; $step.LogCursor = if ($hasLog) { 'Hand' } else { 'Arrow' } }
            'Failed'    { $step.LogFill = '#dc2626'; $step.LogStroke = '#dc2626'; $step.LogCursor = if ($hasLog) { 'Hand' } else { 'Arrow' } }
        }
    }
    Refresh-Grids
}

$timer.Add_Tick({
    if ($script:ProgressPath -and (Test-Path -LiteralPath $script:ProgressPath)) {
        # The runner process has this file open for an Add-Content append at the
        # same moment this timer can fire, which occasionally trips a sharing
        # violation. It's transient and self-resolves within milliseconds -- skip
        # this tick and pick the file back up on the next one instead of letting
        # the IOException escape to the script-level trap and abort the run.
        try {
            $lines = @(Get-Content -LiteralPath $script:ProgressPath -ErrorAction Stop)
        } catch {
            $lines = $null
        }
        if ($null -ne $lines) {
            # Only touch the grids when the log actually grew. Items.Refresh() tears
            # down and rebuilds the DataGrid's visual rows, so calling it on every
            # 1-second tick regardless of whether anything changed caused the whole
            # grid to visibly flicker for the entire run.
            if ($lines.Count -gt $script:SeenProgressLines) {
                $processedThrough = $script:SeenProgressLines
                for ($i = $script:SeenProgressLines; $i -lt $lines.Count; $i++) {
                    if ([string]::IsNullOrWhiteSpace($lines[$i])) { $processedThrough = $i + 1; continue }
                    # The runner process appends to this file (Add-Content) while this
                    # timer reads it (Get-Content) roughly once a second, on a separate
                    # process. A tick can land mid-write and see a torn/partial JSON
                    # line. Rather than let that crash the whole UI (it used to: the
                    # ConvertFrom-Json failure escaped to the script-level trap and
                    # aborted the run), stop at the bad line and leave it for the next
                    # tick, by which point the write will have completed and the line
                    # will parse cleanly.
                    try {
                        $event = $lines[$i] | ConvertFrom-Json
                    } catch {
                        break
                    }
                    $match = @($steps | Where-Object { $_.Id -eq $event.step } | Select-Object -First 1)
                    if ($match.Count) {
                        $match[0].Status = (Get-Culture).TextInfo.ToTitleCase([string]$event.status)
                        $match[0].Detail = [string]$event.message
                        $match[0].Log = [string]$event.logPath
                    }
                    $processedThrough = $i + 1
                }
                if ($processedThrough -gt $script:SeenProgressLines) {
                    $script:SeenProgressLines = $processedThrough
                    Update-LogIndicators
                }
            }
        }
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
        $degradedSteps = @($steps | Where-Object { $_.Selected -and $_.Status -eq 'Degraded' })
        $exportedSteps = @($steps | Where-Object { $_.Selected -and $_.Status -eq 'Exported' })
        $script:LastRunHadExport = $false
        if ($failedCount -gt 0 -or $exitCode -ne 0) {
            (Find-Control FinalBanner).Background = '#fbeeef'
            (Find-Control FinalBanner).BorderBrush = '#ecc5c8'
            (Find-Control FinalMessage).Foreground = '#6a151a'
            $plural = if ($failedCount -eq 1) { 'step' } else { 'steps' }
            $text = "$failedCount selected $plural failed. Review the log and rerun only the failed step."
            if ($reason) { $text = "$text`n`n$reason" }
            (Find-Control FinalMessage).Text = $text
            (Find-Control RerunFailedButton).Content = 'Rerun failed step'
        } elseif ($exportedSteps.Count -gt 0) {
            # Not resumable in this run: no target-org calls were made at all, so
            # there is no "rerun this step" -- the coordinator hands the exported
            # file off and starts a brand-new run once the target project exists.
            (Find-Control FinalBanner).Background = '#DDF2F7'
            (Find-Control FinalBanner).BorderBrush = '#b9dcf7'
            (Find-Control FinalMessage).Foreground = '#0f3a5c'
            (Find-Control FinalMessage).Text = "Process exported: $($exportedSteps[0].Detail)"
            (Find-Control RerunFailedButton).Content = 'Start New Run'
            $script:LastRunHadExport = $true
        } elseif ($degradedSteps.Count -gt 0) {
            # Not a failure: the step stopped cleanly and is waiting on a manual,
            # UI-only action in Azure DevOps before it can finish.
            (Find-Control FinalBanner).Background = '#fff4e5'
            (Find-Control FinalBanner).BorderBrush = '#f5d7a1'
            (Find-Control FinalMessage).Foreground = '#7a4a00'
            (Find-Control FinalMessage).Text = "Action needed: $($degradedSteps[0].Detail)"
            (Find-Control RerunFailedButton).Content = 'Continue after manual step'
        } else {
            (Find-Control FinalBanner).Background = '#eaf7ea'
            (Find-Control FinalBanner).BorderBrush = '#c1e3c1'
            (Find-Control FinalMessage).Foreground = '#114c11'
            (Find-Control FinalMessage).Text = 'All selected steps completed successfully.'
            (Find-Control RerunFailedButton).Content = 'Rerun failed step'
        }
        Update-LogIndicators
        Set-Screen done
    }
})

(Find-Control RunButton).Add_Click({
    $selected = @($steps | Where-Object { $_.Selected })
    if (-not $selected.Count) {
        [System.Windows.MessageBox]::Show('Select at least one step to run.', 'ADO Migration Launcher', 'OK', 'Warning') | Out-Null
        return
    }
    # Validate that if process step is selected, a process name (and, for Full
    # automation, a target project URL) is provided.
    $processSelected = @($selected | Where-Object { $_.Id -eq 'process' }).Count -gt 0
    if ($processSelected) {
        if ([string]::IsNullOrWhiteSpace((Find-Control ProcessNameBox).Text)) {
            [System.Windows.MessageBox]::Show('Process migration (Step 0) is selected but the process name is missing. Please provide a process name, or deselect Step 0.', 'ADO Migration Launcher', 'OK', 'Warning') | Out-Null
            return
        }
        if ((Find-Control ModeFullAutoRadio).IsChecked -and [string]::IsNullOrWhiteSpace((Find-Control TargetUrlBox).Text)) {
            [System.Windows.MessageBox]::Show('Full automation mode needs a target project URL to know what to create.', 'ADO Migration Launcher', 'OK', 'Warning') | Out-Null
            return
        }
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
    if (-not [string]::IsNullOrWhiteSpace((Find-Control ProcessNameBox).Text)) {
        $argList += @('-ProcessName', "`"$((Find-Control ProcessNameBox).Text)`"")
        $mode = if ((Find-Control ModeFullAutoRadio).IsChecked) { 'FullAuto' } elseif ((Find-Control ModeExportRadio).IsChecked) { 'ExportOnly' } else { 'AssistedManual' }
        $argList += @('-ProcessMode', $mode)
    }
    # Capture the runner process's own console output (stdout/stderr) to a file.
    # Without this, anything PowerShell itself prints when a script-level trap
    # re-throws (or, worse, a crash severe enough to bypass the trap entirely)
    # simply vanishes: CreateNoWindow=true with no redirection discards it. This
    # is the only remaining record of a runner-process crash if its own JSONL
    # error log turns out empty (see the comment on Write-RunnerCrashLog in
    # ado-project-setup-runner.ps1 for why that can happen).
    $runnerConsoleLogPath = Join-Path $script:RunDirectory 'runner-console.log'
    # -SourceIdentifier takes a single string, not an array -- clear each one by
    # name so a rerun within the same UI session (Run clicked more than once
    # without closing the window) doesn't stack duplicate event handlers.
    foreach ($sourceId in 'RunnerConsoleOut', 'RunnerConsoleErr') {
        Get-EventSubscriber -SourceIdentifier $sourceId -ErrorAction SilentlyContinue | Unregister-Event
    }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = $argList -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $script:RunnerProcess = [Diagnostics.Process]::new()
    $script:RunnerProcess.StartInfo = $psi
    $consoleLogAction = {
        if (-not [string]::IsNullOrEmpty($EventArgs.Data)) {
            Add-Content -LiteralPath $Event.MessageData -Value $EventArgs.Data -Encoding utf8
        }
    }
    Register-ObjectEvent -InputObject $script:RunnerProcess -EventName OutputDataReceived -SourceIdentifier 'RunnerConsoleOut' -Action $consoleLogAction -MessageData $runnerConsoleLogPath | Out-Null
    Register-ObjectEvent -InputObject $script:RunnerProcess -EventName ErrorDataReceived -SourceIdentifier 'RunnerConsoleErr' -Action $consoleLogAction -MessageData $runnerConsoleLogPath | Out-Null
    $script:RunnerProcess.Start() | Out-Null
    $script:RunnerProcess.BeginOutputReadLine()
    $script:RunnerProcess.BeginErrorReadLine()
    $env:ADO_SOURCE_PAT = $null
    $env:ADO_TARGET_PAT = $null
    (Find-Control RunSubtitle).Text = "Do not close this window. Logs are written under $script:RunDirectory"
    Set-Screen run
    $timer.Start()
})

Set-Screen connect
$null = $window.ShowDialog()
Complete-AdoScriptRun -Outcome succeeded -ErrorRecord $null -Operation 'project-setup-ui' -Message 'UI session closed.'
