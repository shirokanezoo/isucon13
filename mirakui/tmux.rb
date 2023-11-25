#!/usr/bin/env ruby
require 'shellwords'

TMUX = 'tmux'
hosts = {
  isu01: 'isu-naruta-001.dev.aws.ckpd.co',
}
WINDOWS = {
  default: [
    {
      panes: [
        { host: hosts[:isu01], command: 'echo 0' },
        { host: hosts[:isu01], command: 'echo 1' },
        { host: hosts[:isu01], command: 'echo 2' },
        { host: hosts[:isu01], command: 'echo 3' },
        { host: hosts[:isu01], command: 'echo 4' },
        { host: hosts[:isu01], command: 'echo 5' },
        { host: hosts[:isu01], command: 'echo 6' },
        { host: hosts[:isu01], command: 'echo 7' },
      ],
    },
    {
      panes: [
        { host: hosts[:isu01], command: 'echo 10' },
        { host: hosts[:isu01], command: 'echo 11' },
      ],
    },
  ],
}

def build_command(windows)
  tmux_commands = []
  windows.each_with_index do |window, win_i|
    window[:panes].each_with_index do |pane, pane_i|
      ssh_command = Shellwords.shelljoin(["ssh", pane[:host]])
      if win_i == 0 && pane_i == 0
        tmux_commands << "new-session #{ssh_command}"
        tmux_commands << "set-hook -g after-split-window 'select-layout tiled'"
      elsif pane_i == 0
        tmux_commands << "new-window #{ssh_command}"
      else
        tmux_commands << "split-window #{ssh_command}"
      end
      if pane[:command]
        command = Shellwords.shellescape(pane[:command])
        tmux_commands << "send-keys #{command} C-m"
      end
      #tmux_commands << "select-layout tiled"
    end
  end
  tmux_commands << 'select-window -t 0'
  tmux_commands << 'attach'
  "#{TMUX} #{tmux_commands.join(' \; ')}"
end

name = ARGV.shift
name = name == nil ? :default : name.to_sym
unless WINDOWS.has_key?(name)
  puts "Usage: #{$0} [#{WINDOWS.keys.map(&:to_s).join('|')}]"
  exit 1
end

cmd = build_command(WINDOWS[name])
puts cmd
exec cmd

