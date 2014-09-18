#!/usr/bin/env python

import getopt
import sys
import yaml
import os
import subprocess
import shutil
import hashlib
import datetime
import shlex
import stat

# Build scripts version string.
build_sh_version_string = "build.sh 0.1"

# Maker class.
class Maker:

	def __init__(self, settings):

		self.drush = settings.get('drush', 'drush')
		self.temp_build_dir = os.path.abspath(settings['temporary'])
		self.final_build_dir = os.path.abspath(settings['final'])
		self.old_build_dir = os.path.abspath(settings.get('previous', 'previous'))
		self.makefile = os.path.abspath(settings.get('makefile', 'conf/site.make'))
		self.profile_name = settings.get('profile', 'standard')
		self.site_name = settings.get('site', 'A drupal site')
		self.settings = settings
		self.store_old_buids = True
		self.makefile_hash = hashlib.md5(self.makefile).hexdigest()

	# Run make
	def make(self):
		self._precheck()
		self.notice("Building")
		self._drush(self._collect_make_args())
		print "done"
		f = open(self.temp_build_dir + "/buildhash", "w")
		f.write(self.makefile_hash)
		f.close()
		# Remove default.settings.php
		os.remove(self.temp_build_dir + "/sites/default/default.settings.php")
		# Link and copy required files
		self._link()
		self._copy()

	# Existing final build?
	def hasExistingBuild(self):
		return os.path.isdir(self.final_build_dir)

    # Backup current final build
	def backup(self):
		self.notice("Backing up current build")
		if self.hasExistingBuild():
			self._backup()

    # Purge current final build
	def purge(self):
		self.notice("Purging current build")
		if self.hasExistingBuild():
			self._wipe()

	# Finalize new build to be the final build
	def finalize(self):
		self.notice("Finalizing new build")
		if os.path.isdir(self.final_build_dir):
			shutil.rmtree(self.final_build_dir)
		os.rename(self.temp_build_dir, self.final_build_dir)

	# Print notice
	def notice(self, *args):
		print "\033[92m** BUILD NOTICE: \033[0m" + ' '.join(str(a) for a in args)

	# Print errror
	def error(self, *args):
		print "\033[91m** BUILD NOTICE: \033[0m" + ' '.join(str(a) for a in args)

	# Print warning
	def warning(self, *args):
		print "\033[93m** BUILD WARNING: \033[0m" + ' '.join(str(a) for a in args)

    # Run install
	def install(self):
		self._drush([
			"--root=" + format(self.final_build_dir),
			"site-install",
			self.profile_name,
			"install_configure_form.update_status_module='array(FALSE,FALSE)'"
			"--account-name=admin",
			"--account-pass=admin",
			"--site-name=" + self.site_name,
			"-y"
		]);

    # Update existing final build
	def update(self):
		if self._drush([
			"--root=" + format(self.final_build_dir),
			'updatedb',
			'--y',
			self.final_build_dir + '/db.sql'
		], True):
			self.notice("Update process completed")
		else:
			self.warning("Unable to update")


	# Execute a shell command
	def shell(self, command): 
		if isinstance(command, list):
			for step in command:
				value = subprocess.call(shlex.split(step)) == 0
				if not value:
					return False
			return True
		else:
			return subprocess.call(shlex.split(command)) == 0

	# Execute given step
	def execute(self, step):
		
		command = False
		if isinstance(step, dict):
			step, command = step.popitem()
	
		if step == 'make':
			self.make()
		elif step == 'backup':
			self.backup()
		elif step == 'purge':
			self.purge()
		elif step == 'finalize':
			self.finalize()
		elif step == 'install':
			self.install()
		elif step == 'update':
			self.update()
		elif step == 'shell':
			self.shell(command)
		else:
			print "Unknown step " + step


	# Collect make args
	def _collect_make_args(self): 
		return [
			"--strict=0",
			"--concurrency=20"
			"-y",
			"make",
			self.makefile,
			self.temp_build_dir
		]


    # Handle link
	def _link(self):
		if not "link" in self.settings:
			return
		for tuple in self.settings['link']:
			source, target = tuple.popitem()
			target = self.temp_build_dir + "/" + target
			self._link_files(source, target)

    # Handle copy
	def _copy(self):
		if not "copy" in self.settings:
			return
		for tuple in self.settings['copy']:
			source, target = tuple.popitem()
			target = self.temp_build_dir + "/" + target
			self._copy_files(source, target)

	# Execute a drush command
	def _drush(self, args, quiet = False):
		if quiet:
			FNULL = open(os.devnull, 'w')
			return subprocess.call([self.drush] + args, stdout=FNULL, stderr=FNULL) == 0
		return subprocess.call([self.drush] + args) == 0

	# Ensure directories exist
	def _precheck(self):
		# Remove old build it if exists
		if os.path.isdir(self.temp_build_dir):
			shutil.rmtree(self.temp_build_dir)
		if not os.path.isdir(self.old_build_dir):
			os.mkdir(self.old_build_dir)

	# Backup existing final build
	def _backup(self):
		if self._drush([
			"--root=" + format(self.final_build_dir),
			'sql-dump',
			self.final_build_dir + '/db.sql'
		], True):
			self.notice("Database dump taken")
		else:
			self.warning("No database dump taken")

		name = datetime.datetime.now()
		name = name.isoformat()
		
		# Restore write rights to sites/default folder:
		mode = os.stat(self.final_build_dir + "/sites/default").st_mode
		os.chmod(self.final_build_dir + "/sites/default", mode|stat.S_IWRITE)
		shutil.copytree(self.final_build_dir, self.old_build_dir + "/" + name)

	# Wipe existing final build
	def _wipe(self):
		if self._drush([
			'--root=' + format(self.final_build_dir),
			'sql-drop',
			'--y'
		], True):
			self.notice("Tables dropped")
		else:
			self.notice("No tables dropped")
		shutil.rmtree(self.final_build_dir)

	# Symlink file from source to target
	def _link_files(self, source, target):
		source = os.path.relpath(source, os.path.dirname(target))
		os.symlink(source, target)

	# Copy file from source to target
	def _copy_files(self, source, target):
		shutil.copytree(source, target)


# Print help function
def help():
	print 'build.sh [options] [command] [site]'
	print '[command] is one of new, update or clean'
	print '[site] defines the site to build, defaults to default'
	print 'Options:'
	print ' -h --help'
	print '			Print this help'
	print ' -c --config'
	print '			Configuration file to use, defaults to conf/site.yml'
	print ' -v --version'

# Print version function.
def version():
	print build_sh_version_string

# Program main:
def main(argv):

	# Default configuration file to use:
	config_file = 'conf/site.yml'

	# Parse options:
	try:
		opts, args = getopt.getopt(argv, "hcv", ["help", "config=", "version"])
	except getopt.GetoptError:
		help()
		return

	for opt, arg in opts:
		if opt in ('-h', "--help"):
			help()
			return
		elif opt in ("-c", "--config"):
			config_file = arg
		elif opt in ("-v", "--version"):
			version()
			return

	try:

		# Get the settings file YAML contents.
		f = open(config_file)
		if f:
			settings = yaml.safe_load(f)
			f.close()
		else:
			print "No configuration file"
			return

		try:			
			command = args[0]
		except IndexError:
			help()
			return

		# Default site is "default"
		site = 'default'
		try:
			site = args[1]
		except IndexError:
			site = 'default'

		sites = []
		sites.append(site)

		for site in sites:

			# Copy defaults.
			site_settings = settings["default"].copy()

			# If not the default site, update it with defaults.
			if site != "default":
				site_settings.update(settings[site])

			# Create the site maker based on the settings
			maker = Maker(site_settings)

			# Execute the command(s).
			if command in settings['commands']:
				command_set = settings['commands'][command]
				for step in command_set:
					maker.execute(step)
			else:
				print "No such command defined as '" + command + "'"

	except Exception, errtxt:

		print "ERROR: %s" % (errtxt)

# Entry point.
if __name__ == "__main__":
	main(sys.argv[1:])