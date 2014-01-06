require 'fileutils'
require 'tmpdir'
require 'optparse'

HOMEDIR = ENV['HOME']
if HOMEDIR.nil?
  STDERR.puts "Environment variable 'HOME' is not available"
  exit 1
end

DEBUGINFO_DIR = File.join(HOMEDIR, ".debuginfo")
SRPM_DIR = File.join(HOMEDIR, ".srpm")

def debug(msg)
  STDERR.puts "debug: #{msg}" if $debug_opt
end

def expect(condition, msg)
  raise msg if not condition
end

module Install

  extend(self)

  def exec(pkg)
    install_main(pkg)
  end

  private

  # pkg            : e.g. ../httpd-debuginfo-1.0.rpm
  # @src_root      : "usr/src/debug" for debuginfo
  #                  ""              for srpm
  # @dest_root     : "$HOME/.debuginfo" for debuginfo
  #                  "$HOME/.srpm"      for srpm
  # @dest_path     : e.g. $HOME/.debuginfo/httpd-debuginfo-1.0
  # @pkg_full_path : e.g. /root/httpd-debuginfo-1.0.rpm
  # @pkg_basename  : e.g. httpd-debuginfo-1.0
  class InstallInfo
    attr_reader :src_root, :dest_root, :dest_path 
    attr_reader :pkg_full_path, :pkg_basename

    def initialize(pkg)
      @dest_root, @src_root, ext \
                     = get_dir_info(pkg)
      @pkg_basename  = File.basename(pkg, ext)
      @pkg_full_path = File.expand_path(pkg)
      @dest_path     = File.join(@dest_root, @pkg_basename)
    end

    private

    def get_dir_info(pkg)
      case File.basename(pkg)
      when /\.src\.rpm\z/
        [SRPM_DIR, "", ".src.rpm"]
      when /-debuginfo-.*\.rpm\z/
        [DEBUGINFO_DIR, "usr/src/debug", ".rpm"]
      else
        expect false, "'#{pkg}' is not .src.rpm or -debuginfo-"
      end
    end
  end

  def install_main(pkg)
    expect File.exists?(pkg), "file '#{pkg}' does not exist"
    expect rpm_file?(pkg), "file '#{pkg}' is not rpm file"
    info = InstallInfo.new(pkg)

    if installed?(info)
      puts "#{pkg} is already installed"
      return
    end

    puts "[Install] #{info.pkg_basename}"
    puts "  Install: start"
    expand_and_install(info)

    if installed?(info)
      puts "  Install: completed successfully"
      make_symlink(info)
    else
      puts "  Install: failed"
    end
  end

  def expand_and_install(info)
    make_new_directory(info.dest_root)
    Dir.mktmpdir do |tmpdir|
      expand_dir = File.join(tmpdir, "expand")
      make_new_directory(expand_dir)
      expand(info.pkg_full_path, expand_dir)

      srcdir  = File.join(expand_dir, info.src_root)
      destdir = info.dest_path
      FileUtils.move(srcdir, destdir)
    end
  end

  def expand(pkg_full_path, expand_dir)
    ["rpm2cpio", "cpio"].each do |cmd|
      expect command_installed?(cmd), "#{cmd} is not installed"
    end

    FileUtils.chdir(expand_dir) do |path|
      `rpm2cpio #{pkg_full_path} | cpio -id 2> /dev/null`
      expect $?.success?,
        "failed to execute rpm2cpio or cpio" 
    end
  end

  def make_symlink(info)
    src  = info.dest_path
    dest = File.join(FileUtils.pwd, info.pkg_basename)
    debug "try to make link\n\tfrom #{src}\n\tto #{dest}"
    if File.exists?(dest)
      debug "#{dest} has already existed. return."
      return
    end
    puts "[Link] #{File.basename(dest)}"
    FileUtils.ln_s(src, dest)
  end

  def make_new_directory(dirname)
    debug "try to make new directory #{dirname}"
    if File.exists?(dirname)
      expect File.directory?(dirname),
        "#{dirname} exists, but it is not directory"
      debug "#{dirname} has already existed"
      return
    end

    FileUtils.mkdir(dirname)
    expect File.exists?(dirname),
      "creating new directory #{dirname} failed"
  end

  def command_installed?(cmd)
    `which #{cmd} 2> /dev/null`
    $?.success?
  end

  def rpm_file?(path)
    `file -b #{path} 2> /dev/null` =~ /\ARPM/
  end

  def installed?(info)
    File.exists?(info.dest_path)
  end
end

module Remove_Link_Common

  private

  def for_each_target_paths(search_name)
    search_dirs = [DEBUGINFO_DIR, SRPM_DIR]
    list = collect_target_dirs(search_dirs, search_name)

    if list.length == 0
      puts "No Target."
      return
    end

    puts "Target Files:"
    list.each do |path|
      puts "  " + path
    end
    puts "\n"

    return unless confirm

    puts "\n"
    list.each do |path|
      yield(path)
    end
  end

  def collect_target_dirs(root_dirs, name)
    return [] if name.nil? || name.empty?

    root_dirs.inject([]) { |r, dir|
      r + (File.directory?(dir) ? Dir[File.join(dir, name)] : []) 
    }.find_all { |path| File.directory?(path) }
  end

  def confirm
    while true
      puts "ok?(y/n)"
      case STDIN.gets
      when /^y$|^yes$/i; return true
      when /^n$|^no$/i; return false
      end
    end
  end
end

module Remove

  include Remove_Link_Common

  extend(self)

  def exec(name)
    for_each_target_paths(name) do |path|
      puts "[Remove] #{File.basename(path)}"
      FileUtils.remove_entry_secure(path)
    end
  end
end

module Link

  include Remove_Link_Common

  extend(self)

  def exec(name, dest_dir)
    dest_dir = FileUtils.pwd if (dest_dir.nil? || dest_dir.empty?)
    expect File.directory?(dest_dir), "#{dest_dir} is not directory" 

    puts "Destination: #{dest_dir}"

    for_each_target_paths(name) do |path|
      basename = File.basename(path)
      dest = File.join(dest_dir, basename)
      debug "try to make link for #{path}"
      if not File.exists?(dest)
        puts "[Link] #{basename}"
        FileUtils.ln_s(path, dest)
      end
    end
  end
end

module List

  extend(self)

  def exec(name)
    name = (name.nil? || name.empty?) ? "*" : 
                   name.include?("*") ? name : "*#{name}*"
    puts "Search String = '#{name}'\n\n"
    show_list(DEBUGINFO_DIR, name)
    show_list(SRPM_DIR, name)
  end

  private

  def show_list(dir, name)
    puts dir + ":"
    dirs = Dir[File.join(dir, name)]
    puts "  <no files>" if dirs.empty?
    dirs.each do |path|
      puts "  " + File.basename(path) if File.directory?(path)
    end
    puts "\n"
  end
end

class Command
  attr_reader :name, :synopsis

  def initialize(name, synopsis, range, &f)
    @name = name
    @synopsis = synopsis
    @range = range
    @f = f
  end

  def execute(args)
    raise "Usage: #{@synopsis}" unless @range === args.length
    @f.call(args)
  end
end

class CommandList
  def self.create
    command_list = []
    synopsis = "install <package>"
    command_list << Command.new("install", synopsis, (1..1)) do |args|
      Install.exec(args[0])
    end

    synopsis = "list [<package name>]"
    command_list << Command.new("list", synopsis, (0..1)) do |args|
      List.exec(args[0])
    end

    synopsis = "remove <package name>"
    command_list << Command.new("remove", synopsis, (1..1)) do |args|
      Remove.exec(args[0])
    end

    synopsis = "link <package name> [<destination directory>]"
    command_list << Command.new("link", synopsis, (1..2)) do |args|
      Link.exec(args[0], args[1])
    end

    command_list
  end
end
  


opt = OptionParser.new
opt.on('-v', 'debug') { $debug_opt = true }
opt.parse!(ARGV)

command_list = CommandList.create

if ARGV.length < 1
  STDERR.puts "Usage:"
  command_list.each do |cmd|
    STDERR.puts "  ruby #{File.basename(__FILE__)} #{cmd.synopsis}"
  end
  exit 1
end

cmd_name = ARGV.shift
cmd = command_list.find { |x| x.name == cmd_name }

if cmd.nil?
  STDERR.puts "command #{cmd_name} not found"
  exit 1
end

begin
  cmd.execute(ARGV)
rescue => e
  STDERR.puts "Error: #{e}" 
  e.backtrace.each { |x| debug x }
end

