module main

import os
import v.pref
import v.util

fn main() {
	vroot := os.dir(pref.vexe_path())
	os.chdir(vroot)

	println('Updating V...')

	// git pull
	git_result := os.exec('git pull --rebase origin master') or {
		panic(err)
	}

	if git_result.exit_code != 0 {
		if git_result.output.contains('Permission denied') {
			eprintln('have no access `$vroot`: Permission denied')
		} else {
			eprintln(git_result.output)
		}
		exit(1)
	}

	println(git_result.output)
	v_hash := util.githash(false)
	current_hash := util.githash(true)
	// println(v_hash)
	// println(current_hash)
	if v_hash == current_hash {
		return
	}

	$if windows {
		backup('v.exe')

		make_result := os.exec('make.bat') or {
			panic(err)
		}
		println(make_result.output)

		backup('cmd/tools/vup.exe')
	} $else {
		make_result := os.exec('make') or {
			panic(err)
		}
		println(make_result.output)
	}

	_ := os.exec('v cmd/tools/vup.v') or {
		panic(err)
	}
}

fn backup(file string) {
	backup_file := '${file}_old.exe'
	if os.exists(backup_file) {
		os.rm(backup_file)
	}
	os.mv(file, backup_file)
}
