#!/usr/bin/env ruby

require 'fileutils'
require 'ftools'
require 'optparse'

$:.unshift File.join(File.dirname(__FILE__), '..', '..', 'lib')

require 'phusion_passenger'

CFGLIMIT=%w{fedora-{13,14} epel-5}

stage_dir='./stage'

mock_base_dir = '/var/lib/mock'
mock_repo_dir = "#{mock_base_dir}/passenger-build-repo"
mock_etc_dir='/etc/mock'
#mock_etc_dir='/tmp/mock'

# If rpmbuild-md5 is installed, use it for the SRPM, so EPEL machines can read it.
rpmbuild = '/usr/bin/rpmbuild' + (File.exist?('/usr/bin/rpmbuild-md5') ? '-md5' : '')
rpmtopdir = `rpm -E '%_topdir'`.chomp
rpmarch = `rpm -E '%_arch'`.chomp

@verbosity = 0

@can_build	 = {
	'i386'		=> %w{i586 i686},
	'i686'		=> %w{i586 i686},
	'ppc'			=> %w{},
	'ppc64'		=> %w{ppc},
	's390x'		=> %w{},
	'sparc'		=> %w{},
	'sparc64' => %w{sparc},
	'x86_64'	=> %w{i386 i586 i686},
}

#@can_build.keys.each {|k| @can_build[k].push k}
@can_build = @can_build[rpmarch.to_s == '' ? 'x86_64' : rpmarch]
@can_build.push rpmarch

bindir=File.dirname(File.expand_path __FILE__)

configs = Dir["#{mock_etc_dir}/{#{CFGLIMIT.join ','}}*"].map {|f| f.gsub(%r{.*/([^.]*).cfg}, '\1')}

def limit_configs(configs, limits)
	tree = configs.inject({}) do |m,c|
		(distro,version,arch) = c.split /-/
		next m unless @can_build.include?(arch)
		[
			# Rather than construct this list programatically, just spell it out
			'',
			distro,
			"#{distro}-#{version}",
			"#{distro}-#{version}-#{arch}",
			"#{distro}--#{arch}",
			"--#{arch}",
			# doubtful these will be used, but for completeness
			"-#{version}",
			"-#{version}-#{arch}",
		].each do |pattern|
			unless m[pattern]
				m[pattern] = []
			end
			m[pattern].push c
		end
		m
	end
	tree.default = []
	# Special case for no arguments
	limits = [nil] if limits.empty?
	# By splitting and rejoining we normalize the distro--, etc. cases.
	return limits.map do |l|
		parts = l.to_s.split(/-/).map {|v| v == '*' ? nil : v}
		if parts[2] && !@can_build.include?(parts[2])
			abort "ERROR: Cannot build '#{parts[2]}' packages on '#{rpmarch}'"
		end
		tree[parts.join '-']
	end.flatten
end

def noisy_system(*args)
	puts(args.join(' ')) if @verbosity > 0
	system(*args)
end


############################################################################
options = {}
OptionParser.new do |opts|
	opts.banner = "Usage: #{$0} [options] [distro-version-arch] [distro-version] [distro--arch] [*--arch]"

	opts.on("-v", "--[no-]verbose", "Run verbosely. Add more -v's to increase @verbosity") do |v|
		@verbosity += v ? 1 : -1
	end

	opts.on('-s', '--single', 'Only build a single distro-rev-arch set (for this machine)') do |v|
		options[:single] = true
	end

	# Do these with options, because the order matters
	opts.on('-b', '--mock-base-dir DIR', "Mock's base directory. Default: #{mock_base_dir}") do |v|
		#mock_repo_dir = v
		options[:mock_base_dir] = v
	end

	opts.on('-m', '--mock-repo-dir DIR', "Directory for special mock yum repository. Default: #{mock_repo_dir}") do |v|
		#mock_repo_dir = v
		options[:mock_repo_dir] = v
	end

	opts.on("-c", "--mock-config-dir DIR", "Directory for mock configuration. Default: #{mock_etc_dir}") do |v|
		if File.directory?(v)
			mock_etc_dir=v
		else
			abort "No such directory: #{v}"
		end
	end

	opts.on('-d', '--stage-dir DIR', "Staging directory. Default: #{stage_dir}") do |v|
		stage_dir = v
	end

	opts.on('-e', '--extra-packages DIR', "Directory for extra packages to install.") do |v|
		options[:extra_packages] = v
	end

	opts.on('-r', '--include-release', "Also build passenger-release packages") do
		options[:release] = true
	end

	opts.on_tail("-h", "--help", "Show this message") do
		puts opts
		exit
	end
end.parse!

if options.key?(:mock_base_dir) || options.key?(:mock_repo_dir)
	if options.key?(:mock_base_dir)
		mock_base_dir = options[:mock_base_dir]
		mock_repo_dir = "#{mock_base_dir}/passenger-build-repo"
	end
	if options.key?(:mock_repo_dir)
		mock_repo_dir = options[:mock_repo_dir]
		unless mock_repo_dir[0] == '/'[0]
			mock_repo_dir = "#{mock_base_dir}/#{mock_repo_dir}"
		end
	end
end

limit = ARGV
if options.key?(:single)
	# This can probably be simplified
	limit = [`rpm --queryformat '%{name}\t%{version}' -qf /etc/redhat-release`.sub(/(\w+)-release\t(\d+)/,'\1-\2').sub(/^(rhel|centos|sl)-/,'epel-') + "-#{`rpm -E '%{_host_cpu}'`.strip}"]
end

configs = limit_configs(configs, limit)

if configs.empty?
	abort "Can't find a set of configs for '#{ARGV[0]}' (hint try 'fedora' or 'fedora-14' or even 'fedora-14-x86_64')"
end

puts "BUILD:\n	" + configs.join("\n	") if @verbosity >= 2

# Too much of what follows expects this. Revisit it later.
Dir.chdir(File.join(File.dirname(__FILE__), '..'))

FileUtils.rm_rf(stage_dir, :verbose => @verbosity > 0)
FileUtils.mkdir_p(stage_dir, :verbose => @verbosity > 0)

ENV['BUILD_VERBOSITY'] = @verbosity.to_s

# Check the ages of the configs for validity
mtime = File.mtime("#{bindir}/mocksetup.sh")
if configs.any? {|c| mtime > File.mtime("#{mock_etc_dir}/passenger-#{c}.cfg") rescue true }
	unless noisy_system("#{bindir}/mocksetup.sh", mock_repo_dir, mock_etc_dir)
		abort <<EndErr
Unable to run "#{bindir}/mocksetup.sh #{mock_repo_dir}". It is likely that you
need to run this command as root the first time, but if you have already done
that, it could also be that the current user (or this shell) is not in the
'mock' group.
EndErr
	end
end

srcdir=`rpm -E '%{_sourcedir}'`.chomp

FileUtils.ln_sf(Dir["#{Dir.getwd}/{config/,patches/,release/RPM-GPG}*"], srcdir, :verbose => @verbosity > 0)

# Force the default versions in the spec file to be the ones in the source so a given SRPM doesn't need a --define to set versions.
specdir="/tmp/#{`whoami`.strip}-specfile-#{Process.pid}"
FileUtils.rm_rf(specdir, :verbose => @verbosity > 0)
begin
	FileUtils.mkdir_p(specdir, :verbose => @verbosity > 0)
	FileUtils.cp('passenger.spec', specdir, :verbose => @verbosity > 0)
	# + must be escaped, but * doesn't? And people wonder why I hate sed.
	abort "Can't edit specfile" unless noisy_system('sed', '-i',
		'-e', "s/^\\(\\([[:space:]]*\\)%define[[:space:]]\\+passenger_version[[:space:]]\\)\\+[0-9.]\\+.*/\\2# From Passenger Source\\n\\1#{PhusionPassenger::VERSION_STRING}/",
		'-e', "s/^\\(\\([[:space:]]*\\)%define[[:space:]]\\+nginx_version[[:space:]]\\)\\+[0-9.]\\+.*/\\2# From Passenger Source\\n\\1#{PhusionPassenger::PREFERRED_NGINX_VERSION}/",
		"#{specdir}/passenger.spec")
	# No dist for SRPM
	unless noisy_system(rpmbuild, *((@verbosity > 0 ? [] : %w{--quiet}) + ['--define', 'dist %nil', '-bs', "#{specdir}/passenger.spec"]))
		abort "No SRPM was built. See above for the error"
	end
ensure
	 FileUtils.rm_rf(specdir, :verbose => @verbosity > 0)
end

srpm="rubygem-passenger-#{PhusionPassenger::VERSION_STRING}-#{`grep '%define passenger_release' passenger.spec | awk '{print $3}'`.strip}.src.rpm".sub(/%\{[^}]+\}/, '')

FileUtils.mkdir_p(stage_dir + '/SRPMS', :verbose => @verbosity > 0)

FileUtils.cp("#{rpmtopdir}/SRPMS/#{srpm}", "#{stage_dir}/SRPMS", :verbose => @verbosity > 0)

if options[:release]
	# It's not EXACTLY equivalent, is it? (REALLY doesn't want to symlink to a different name)
	# FileUtils.ln_sf(Dir["#{Dir.getwd}/release/mirrors"], "#{srcdir}/mirrors-passenger", :verbose => @verbosity > 0)
	FileUtils.ln_sf(Dir["#{Dir.getwd}/release/mirrors"], srcdir, :verbose => @verbosity > 0)
	FileUtils.rm_f( "#{srcdir}/mirrors-passenger", :verbose => @verbosity > 0)
	FileUtils.mv("#{srcdir}/mirrors", "#{srcdir}/mirrors-passenger", :force => true, :verbose => @verbosity > 0)
	unless noisy_system(rpmbuild, *((@verbosity > 0 ? [] : %w{--quiet}) + ['--define', 'dist %nil', '-bs', "passenger-release.spec"]))
		abort "No passenger-release SRPM was built. See above for the error"
	end
	rel_version = `grep '^Version:' passenger-release.spec | awk '{print $2}'`.to_i
	rel_release = `grep '^Release:' passenger-release.spec | awk '{print $2}'`.to_i
	@rel_srpm = "passenger-release-#{rel_version}-#{rel_release}.src.rpm"
	FileUtils.cp("#{rpmtopdir}/SRPMS/passenger-release-#{rel_version}-#{rel_release}.src.rpm",
							 "#{stage_dir}/SRPMS", :verbose => @verbosity > 0)
end

mockvolume = @verbosity >= 2 ? %w{-v} : @verbosity < 0 ? %w{-q} : []

@release_cache = {}

configs.each do |cfg|
	puts "---------------------- Building #{cfg}" if @verbosity >= 0
	pcfg = 'passenger-' + cfg

	idir = './pkg'

	unless options.key?(:single)
		idir = File.join stage_dir, cfg.split(/-/)
	end

	# Move *mockvolume to the end, since it causes Ruby to cry in the middle
	# Alt sol'n: *(foo + ['bar'] )
	unless noisy_system('mock', '-r', pcfg, "#{stage_dir}/SRPMS/#{srpm}", *mockvolume)
		abort "Mock failed. See above for details"
	end
	FileUtils.mkdir_p(idir, :verbose => @verbosity > 0)
	FileUtils.cp(Dir["#{mock_base_dir}/#{pcfg}/result/*.rpm"],
							 idir, :verbose => @verbosity > 0)
	if options.key?(:extra_packages)
		FileUtils.cp(Dir["#{options[:extra_packages]}/*.rpm"], idir, :verbose => @verbosity > 0)
	end

	if options[:release]
		cache_key = cfg.split(/-/).first(2).join('-')
		# There is little sense in rebuilding a noarch package over & over
		if @release_cache[cache_key]
			FileUtils.cp(@release_cache[cache_key], idir, :verbose => @verbosity > 0)
		else
			unless noisy_system('mock', '-r', pcfg, "#{stage_dir}/SRPMS/#{@rel_srpm}", *mockvolume)
				abort "Release Mock failed. See above for details"
			end

			FileUtils.cp(Dir["#{mock_base_dir}/#{pcfg}/result/*.rpm"],
									 idir, :verbose => @verbosity > 0)
			@release_cache[cache_key] = Dir["#{idir}/passenger-release*noarch.rpm"].last
		end
	end

	FileUtils.rm_f(Dir["#{idir}/*.src.rpm"], :verbose => @verbosity > 1)
end

unless options.key?(:single)
	if File.directory?("#{stage_dir}/epel")
		FileUtils.mv "#{stage_dir}/epel", "#{stage_dir}/rhel", :verbose => @verbosity > 0
	end
end

if options[:release]
	Dir["#{stage_dir}/*/*"].each do |distro_version|
		next unless File.directory?(distro_version)
		arch = Dir["#{distro_version}/{#{@can_build.sort.join ','}}"].last
		pkg = Dir["#{arch}/passenger-release*rpm"].last
		pkg = pkg.split(/#{File::SEPARATOR}/).last(2)
		FileUtils.ln_sf(File.join(pkg), "#{distro_version}/passenger-release.noarch.rpm", :verbose => @verbosity > 0)
	end
end

unless `rpm -E '%{?_gpg_name}'`.strip == ''
	signor=`rpm -E '%{_gpg_name}'`.strip
	key=`gpg --list-key #{signor} | grep '^pub' | awk '{print $2}' | cut -d/ -f2`
	# Don't re-sign packages already signed by your key
	files=Dir["#{options.key?(:single) ? 'pkg' : stage_dir}/**/*.rpm"].select do |rpm|
		!File.symlink?(rpm) && (`rpm --checksig #{rpm}` !~ /#{key}/)
	end

	noisy_system('rpm', '--addsign', *files)
end
