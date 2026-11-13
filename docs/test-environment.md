# The default test environment

`monitoring_settings.json` ships with a configuration that works on any Windows 10/11 PC, with no setup: every
category watches something every Windows machine has, and a few **demo toggles** let you trigger an alert and its
recovery on purpose.

Start everything with `start_monitoring.bat`, open the console at <http://localhost:5758>, and keep
`logs/monitor.log` open in an editor to watch the alert lines arrive.

## What is watched

| Category | Item | Normal state | Demo toggle |
|---|---|---|---|
| Processes | Windows Explorer (`explorer.exe`) | Running | — |
| Processes | Desktop Window Manager (`dwm.exe`) | Running | — |
| Processes | Notepad (`notepad.exe`) | **Not running** | Open / close Notepad |
| Performance | CPU | Warning ≥ 80 % for 30 s, critical ≥ 95 % for 60 s | Lower a threshold in the editor |
| Performance | Memory (RAM) | Warning ≥ 85 % for 30 s, critical ≥ 95 % for 30 s | Lower a threshold in the editor |
| Disk | System drive `C:\` | Warning ≥ 75 % used, critical ≥ 90 % | Lower a threshold in the editor |
| Network | Cloudflare DNS `1.1.1.1` (ping) | Online | Disconnect from the network |
| Network | Google DNS `8.8.8.8` (TCP 53) | Online | Disconnect from the network |
| Network | Monitoring console `localhost:5758` | Online while the console runs | Close the console |
| Network | Settings editor `localhost:5757` | **Warning until you open the editor** | **Open Monitoring settings** in the console |
| Document | `sample_data/monthly_budget_sample.csv`: Groceries vs a $400 budget | **Warning** ($340.15 = 85 %) | Edit an amount in the CSV |

So a fresh start shows a few deliberate non-green rows: Notepad (not running), the settings editor (closed) and the
budget (at 85 %). Each one can be turned green.

## Trigger each alert

### Process: Notepad

1. Open **Notepad**. Within 30 s its row turns green.
2. Close it. Within 30 s the row turns red with an alert count, `logs/monitor.log` gets
   `WARNING PROC: Notepad (demo) (notepad.exe) not detected.`, and **Perform Actions** shows the runbook.
3. Open it again: the log records `RECOVERY: notepad.exe is running again (was down …)`.

### Performance: CPU or memory

1. Open the settings editor (`start_editor.bat`), go to **Memory Performance**, and set the warning threshold a few
   points below the console's current RAM value, with **Sustain (sec)** at `10`. Save.
2. Restart the monitors (`start_monitoring.bat`); monitors read the settings at startup.
3. After 10 s the row turns orange and the log gets `WARNING MEM: …`. The incident stays open while RAM hovers
   around the line, and closes once RAM is 5 points under it for the sustain time.

The same works for CPU. For a **critical** alert, lower the critical threshold instead: it also opens an email draft
(once per hour per alert, see [Incidents, spam guard and email cooldown](configuration.md#incidents-spam-guard-and-email-cooldown))
and runs `scripts/actions/on_memory_critical.ps1`.

### Disk

Set the disk warning threshold (editor → **Disk**) just below the current *% used* and restart the monitors. The
alert fires on the next check (every 60 s).

### Network: the settings editor

1. Click **Open Monitoring settings** in the console's demo banner (or run `start_editor.bat`). Within 30 s the
   **Settings Editor (demo)** row turns green.
2. Stop the editor: run `stop_monitoring.bat`, or close the `start_editor.bat` window if you started it that way. The row goes back to *warning* and the log gets
   `WARNING SVC: settings editor on localhost:5757 is not running (demo)`.

To see a **critical** network alert, disconnect from Wi-Fi: both DNS rows go red and `on_network_down.ps1` runs.

### Document: the monthly budget

1. Open `sample_data/monthly_budget_sample.csv` in Notepad (or click **Open File** in the editor's **Document**
   panel).
2. Change the last Groceries amount from `22.00` to `90.00` and save. The total becomes $408.15 = 102 % of the
   budget.
3. Within 30 s the card turns red: **critical**, a popup appears, an email draft opens, and the log gets
   `CRITICAL DOC: Groceries spend (monthly budget) at $408.15 (102% of $400; threshold 100%)`.
4. Change it back to `22.00`. The card returns to *warning* once the total is under 95 % (the 5-point margin).

The document is re-read every cycle, and so are its settings: try changing `target` in the editor, no restart needed.

## Make it your own

Replace the demo items with what matters on your machine: the processes your applications need, your servers'
hosts and ports, your drives, and the CSV or workbook your team keeps a number in. The full schema is in
[configuration.md](configuration.md); run `doctor.bat` after every change.
