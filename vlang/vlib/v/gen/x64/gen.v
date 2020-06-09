// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module x64

import v.ast
import v.util
import term
import strings

pub struct Gen {
	out_name             string
mut:
	buf                  []byte
	sect_header_name_pos int
	offset               i64
	str_pos              []i64
	strings              []string // TODO use a map and don't duplicate strings
	file_size_pos        i64
	main_fn_addr         i64
	code_start_pos       i64 // location of the start of the assembly instructions
	fn_addr              map[string]i64
	var_offset           map[string]int // local var stack offset
	stack_var_pos        int
	debug_pos            int
}

// string_addr map[string]i64
// The registers are ordered for faster generation
// push rax => 50
// push rcx => 51 etc
enum Register {
	rax
	rcx
	rdx
	rbx
	rsp
	rbp
	rsi
	rdi
	eax
	edi
	edx
	r8
	r9
	r10
	r11
	r12
	r13
	r14
	r15
}

const (
	fn_arg_registers = [x64.Register.rdi, .rsi, .rdx, .rcx, .r8, .r9]
)

/*
rax // 0
	rcx // 1
	rdx // 2
	rbx // 3
	rsp // 4
	rbp // 5
	rsi // 6
	rdi // 7
*/
enum Size {
	_8
	_16
	_32
	_64
}

pub fn gen(files []ast.File, out_name string) {
	mut g := Gen{
		sect_header_name_pos: 0
		out_name: out_name
	}
	g.generate_elf_header()
	for file in files {
		g.stmts(file.stmts)
	}
	g.generate_elf_footer()
}

pub fn (mut g Gen) stmts(stmts []ast.Stmt) {
	for stmt in stmts {
		g.stmt(stmt)
	}
}

/*
pub fn new_gen(out_name string) &Gen {
	return &Gen{
		sect_header_name_pos: 0
		buf: []
		out_name: out_name
	}
}
*/
pub fn (g &Gen) pos() i64 {
	return g.buf.len
}

fn (mut g Gen) write8(n int) {
	// write 1 byte
	g.buf << byte(n)
}

fn (mut g Gen) write16(n int) {
	// write 2 bytes
	g.buf << byte(n)
	g.buf << byte(n >> 8)
}

fn (mut g Gen) write32(n int) {
	// write 4 bytes
	g.buf << byte(n)
	g.buf << byte(n >> 8)
	g.buf << byte(n >> 16)
	g.buf << byte(n >> 24)
}

fn (mut g Gen) write64(n i64) {
	// write 8 bytes
	g.buf << byte(n)
	g.buf << byte(n >> 8)
	g.buf << byte(n >> 16)
	g.buf << byte(n >> 24)
	g.buf << byte(n >> 32)
	g.buf << byte(n >> 40)
	g.buf << byte(n >> 48)
	g.buf << byte(n >> 56)
}

fn (mut g Gen) write64_at(n, at i64) {
	// write 8 bytes
	g.buf[at] = byte(n)
	g.buf[at + 1] = byte(n >> 8)
	g.buf[at + 2] = byte(n >> 16)
	g.buf[at + 3] = byte(n >> 24)
	g.buf[at + 4] = byte(n >> 32)
	g.buf[at + 5] = byte(n >> 40)
	g.buf[at + 6] = byte(n >> 48)
	g.buf[at + 7] = byte(n >> 56)
}

fn (mut g Gen) write32_at(at i64, n int) {
	// write 4 bytes
	g.buf[at] = byte(n)
	g.buf[at + 1] = byte(n >> 8)
	g.buf[at + 2] = byte(n >> 16)
	g.buf[at + 3] = byte(n >> 24)
}

fn (mut g Gen) write_string(s string) {
	for c in s {
		g.write8(int(c))
	}
}

fn (mut g Gen) inc(reg Register) {
	g.write16(0xff49)
	match reg {
		.r12 { g.write8(0xc4) }
		else { panic('unhandled inc $reg') }
	}
}

fn (mut g Gen) cmp(reg Register, size Size, val i64) {
	g.write8(0x49)
	// Second byte depends on the size of the value
	match size {
		._8 { g.write8(0x83) }
		._32 { g.write8(0x81) }
		else { panic('unhandled cmp') }
	}
	// Third byte depends on the register being compared to
	match reg {
		.r12 { g.write8(0xfc) }
		else { panic('unhandled cmp') }
	}
	g.write8(int(val))
}

fn (mut g Gen) get_var_offset(var_name string) int {
	offset := g.var_offset[var_name]
	if offset == 0 {
		panic('0 offset for var `$var_name`')
	}
	return offset
}

// `a == 1`
// `cmp DWORD [rbp-0x4],0x1`
fn (mut g Gen) cmp_var(var_name string, val int) {
	g.write8(0x81) // 83 for 1 byte?
	g.write8(0x7d)
	offset := g.get_var_offset(var_name)
	g.write8(0xff - offset + 1)
	g.write32(val)
	g.println('cmp var `$var_name` $val')
}

// `add DWORD [rbp-0x4], 1`
fn (mut g Gen) inc_var(var_name string) {
	g.write16(0x4581) // 83 for 1 byte
	offset := g.get_var_offset(var_name)
	g.write8(0xff - offset + 1)
	g.write32(1)
	g.println('inc_var `$var_name`')
}

// Returns the position of the address to jump to (set later).
fn (mut g Gen) jne() int {
	g.write16(0x850f)
	pos := g.pos()
	g.write32(PLACEHOLDER)
	g.println('jne')
	return pos
}

fn (mut g Gen) jge() int {
	g.write16(0x8d0f)
	pos := g.pos()
	g.write32(PLACEHOLDER)
	g.println('jne')
	return pos
}

fn (mut g Gen) jmp(addr int) {
	g.write8(0xe9)
	g.write32(addr) // 0xffffff
	g.println('jmp')
}

fn abs(a i64) i64 {
	return if a < 0 {
		-a
	} else {
		a
	}
}

fn (mut g Gen) jle(addr i64) {
	// Calculate the relative offset to jump to
	// (`addr` is absolute address)
	offset := 0xff - int(abs(addr - g.buf.len)) - 1
	g.write8(0x7e)
	g.write8(offset)
	g.println('jle')
}

fn (mut g Gen) println(comment string) {
	addr := g.debug_pos.hex()
	// println('$g.debug_pos "$addr"')
	print(term.red(strings.repeat(`0`, 6 - addr.len) + addr + '  '))
	for i := g.debug_pos; i < g.buf.len; i++ {
		s := g.buf[i].hex()
		if s.len == 1 {
			print(term.blue('0'))
		}
		print(term.blue(g.buf[i].hex()) + ' ')
	}
	g.debug_pos = g.buf.len
	print(' ' + comment)
	println('')
}

fn (mut g Gen) jl(addr i64) {
	offset := 0xff - int(abs(addr - g.buf.len)) - 1
	g.write8(0x7c)
	g.write8(offset)
	g.println('jl')
}

fn (g &Gen) abs_to_rel_addr(addr i64) int {
	return int(abs(addr - g.buf.len)) - 1
}

/*
fn (mut g Gen) jmp(addr i64) {
	offset := 0xff - g.abs_to_rel_addr(addr)
	g.write8(0xe9)
	g.write8(offset)
}
*/
fn (mut g Gen) mov64(reg Register, val i64) {
	match reg {
		.rsi {
			g.write8(0x48)
			g.write8(0xbe)
		}
		else {
			println('unhandled mov $reg')
		}
	}
	g.write64(val)
	g.println('mov64 $reg, $val')
}

fn (mut g Gen) mov_from_reg(var_offset int, reg Register) {
	// 89 7d fc                mov    DWORD PTR [rbp-0x4],edi
	g.write8(0x89)
	match reg {
		.edi, .rdi { g.write8(0x7d) }
		.rsi { g.write8(0x75) }
		else { verror('mov_from_reg $reg') }
	}
	g.write8(0xff - var_offset + 1)
	g.println('mov from reg')
}

fn (mut g Gen) call(addr int) {
	// Need to calculate the difference between current position (position after the e8 call)
	// and the function to call.
	// +5 is to get the posistion "e8 xx xx xx xx"
	// Not sure about the -1.
	rel := 0xffffffff - (g.buf.len + 5 - addr - 1)
	// println('call addr=$addr.hex() rel_addr=$rel.hex() pos=$g.buf.len')
	g.write8(0xe8)
	g.write32(rel)
	// g.println('fn call')
}

fn (mut g Gen) syscall() {
	// g.write(0x050f)
	g.write8(0x0f)
	g.write8(0x05)
	g.println('syscall')
}

pub fn (mut g Gen) ret() {
	g.write8(0xc3)
	g.println('ret')
}

pub fn (mut g Gen) push(reg Register) {
	if reg < .r8 {
		g.write8(0x50 + reg)
	} else {
		g.write8(0x41)
		g.write8(0x50 + reg - 8)
	}
	/*
	match reg {
		.rbp { g.write8(0x55) }
		else {}
	}
	*/
	g.println('push $reg')
}

pub fn (mut g Gen) pop(reg Register) {
	g.write8(0x58 + reg)
	// TODO r8...
	g.println('pop $reg')
}

pub fn (mut g Gen) sub32(reg Register, val int) {
	g.write8(0x48)
	g.write8(0x81)
	g.write8(0xe8 + reg) // TODO rax is different?
	g.write32(val)
	g.println('sub $reg,0x$val.hex()')
}

pub fn (mut g Gen) add(reg Register, val int) {
	g.write8(0x48)
	g.write8(0x81)
	g.write8(0xe8 + reg) // TODO rax is different?
	g.write32(val)
	g.println('add $reg,0x$val.hex()')
}

fn (mut g Gen) leave() {
	g.write8(0xc9)
	g.println('leave')
}

// returns label's relative address
pub fn (mut g Gen) gen_loop_start(from int) int {
	g.mov(.r12, from)
	label := g.buf.len
	g.inc(.r12)
	return label
}

pub fn (mut g Gen) gen_loop_end(to, label int) {
	g.cmp(.r12, ._8, to)
	g.jl(label)
}

pub fn (mut g Gen) save_main_fn_addr() {
	g.main_fn_addr = g.buf.len
}

pub fn (mut g Gen) gen_print_from_expr(expr ast.Expr, newline bool) {
	match expr {
		ast.StringLiteral {
			if newline {
				g.gen_print(it.val + '\n')
			} else {
				g.gen_print(it.val)
			}
		}
		else {}
	}
}

pub fn (mut g Gen) gen_print(s string) {
	//
	// qq := s + '\n'
	//
	g.strings << s
	// g.string_addr[s] = str_pos
	g.mov(.eax, 1)
	g.mov(.edi, 1)
	str_pos := g.buf.len + 2
	g.str_pos << str_pos
	g.mov64(.rsi, 0) // segment_start +  0x9f) // str pos // PLACEHOLDER
	g.mov(.edx, s.len) // len
	g.syscall()
}

pub fn (mut g Gen) gen_exit() {
	// Return 0
	g.mov(.edi, 0) // ret value
	g.mov(.eax, 60)
	g.syscall()
}

fn (mut g Gen) mov(reg Register, val int) {
	match reg {
		.eax, .rax {
			g.write8(0xb8)
		}
		.edi, .rdi {
			g.write8(0xbf)
		}
		.edx {
			g.write8(0xba)
		}
		.rsi {
			g.write8(0x48)
			g.write8(0xbe)
		}
		.r12 {
			g.write8(0x41)
			g.write8(0xbc) // r11 is 0xbb etc
		}
		else {
			panic('unhandled mov $reg')
		}
	}
	g.write32(val)
	g.println('mov $reg, $val')
}

fn (mut g Gen) mov_reg(a, b Register) {
	match a {
		.rbp {
			g.write8(0x48)
			g.write8(0x89)
		}
		else {}
	}
}

// generates `mov rbp, rsp`
fn (mut g Gen) mov_rbp_rsp() {
	g.write8(0x48)
	g.write8(0x89)
	g.write8(0xe5)
	g.println('mov rbp,rsp')
}

pub fn (mut g Gen) register_function_address(name string) {
	addr := g.pos()
	// println('reg fn addr $name $addr')
	g.fn_addr[name] = addr
}

pub fn (mut g Gen) call_fn(node ast.CallExpr) {
	name := node.name
	// println('call fn $name')
	addr := g.fn_addr[name]
	if addr == 0 {
		verror('fn addr of `$name` = 0')
	}
	// Copy values to registers (calling convention)
	// g.mov(.eax, 0)
	for i in 0 .. node.args.len {
		expr := node.args[i].expr
		int_lit := expr as ast.IntegerLiteral
		g.mov(fn_arg_registers[i], int_lit.val.int())
	}
	if node.args.len > 6 {
		verror('more than 6 args not allowed for now')
	}
	g.call(int(addr))
	g.println('fn call `${name}()`')
	// println('call $name $addr')
}

fn (mut g Gen) stmt(node ast.Stmt) {
	match node {
		ast.AssignStmt {
			g.assign_stmt(it)
		}
		ast.ConstDecl {}
		ast.ExprStmt {
			g.expr(it.expr)
		}
		ast.FnDecl {
			g.fn_decl(it)
		}
		ast.ForStmt {
			g.for_stmt(it)
		}
		ast.HashStmt {
			words := it.val.split(' ')
			for word in words {
				if word.len != 2 {
					verror('opcodes format: xx xx xx xx')
				}
				b := C.strtol(word.str, 0, 16)
				// b := word.byte()
				// println('"$word" $b')
				g.write8(b)
			}
		}
		ast.Module {}
		ast.Return {
			g.gen_exit()
			g.ret()
		}
		ast.StructDecl {}
		else {
			println('x64.stmt(): bad node: ' + typeof(node))
		}
	}
}

fn C.strtol() int

fn (mut g Gen) expr(node ast.Expr) {
	// println('cgen expr()')
	match node {
		ast.ArrayInit {}
		ast.AssignExpr {}
		ast.CallExpr {
			if it.name in ['println', 'print', 'eprintln', 'eprint'] {
				expr := it.args[0].expr
				g.gen_print_from_expr(expr, it.name in ['println', 'eprintln'])
				return
			}
			g.call_fn(it)
		}
		ast.FloatLiteral {}
		ast.Ident {}
		ast.IfExpr {
			g.if_expr(it)
		}
		ast.InfixExpr {}
		ast.IntegerLiteral {}
		ast.PostfixExpr {
			g.postfix_expr(it)
		}
		ast.StringLiteral {}
		ast.StructInit {}
		ast.BoolLiteral {}
		else {
			// println(term.red('x64.expr(): bad node'))
		}
	}
}

fn (mut g Gen) allocate_var(name string, size, initial_val int) {
	// `a := 3`  =>
	// `move DWORD [rbp-0x4],0x3`
	match size {
		1 {
			// BYTE
			g.write8(0xc6)
			g.write8(0x45)
		}
		4 {
			// DWORD
			g.write8(0xc7)
			g.write8(0x45)
		}
		8 {
			// QWORD
			g.write8(0x48)
			g.write8(0xc7)
			g.write8(0x45)
		}
		else {
			verror('allocate_var: bad size $size')
		}
	}
	// Generate N in `[rbp-N]`
	n := g.stack_var_pos + size
	g.write8(0xff - n + 1)
	g.stack_var_pos += size
	g.var_offset[name] = g.stack_var_pos
	// Generate the value assigned to the variable
	g.write32(initial_val)
	// println('allocate_var(size=$size, initial_val=$initial_val)')
	g.println('mov DWORD [rbp-0x$n],$initial_val (Aallocate var `$name`)')
}

fn (mut g Gen) assign_stmt(node ast.AssignStmt) {
	// `a := 1` | `a,b := 1,2`
	for ident in node.left {
		match node.right[0] {
			ast.IntegerLiteral {
				g.allocate_var(ident.name, 4, it.val.int())
			}
			ast.InfixExpr {
				g.infix_expr(it)
				g.allocate_var(ident.name, 4, 0)
			}
			else {
				verror('assign_stmt unhandled expr')
			}
		}
	}
}

fn (mut g Gen) infix_expr(node ast.InfixExpr) {
	println('infix expr op=$node.op')
	match node.op {
		.plus {}
		else {}
	}
}

fn (mut g Gen) if_expr(node ast.IfExpr) {
	branch := node.branches[0]
	infix_expr := branch.cond as ast.InfixExpr
	mut jne_addr := 0 // location of `jne *00 00 00 00*`
	match infix_expr.left {
		ast.Ident {
			lit := infix_expr.right as ast.IntegerLiteral
			g.cmp_var(it.name, lit.val.int())
			jne_addr = g.jne()
		}
		else {
			verror('unhandled infix.left')
		}
	}
	g.stmts(branch.stmts)
	// Now that we know where we need to jump if the condition is false, update the `jne` call.
	// The value is the relative address, difference between current position and the location
	// after `jne 00 00 00 00`
	// println('after if g.pos=$g.pos() jneaddr=$jne_addr')
	g.write32_at(jne_addr, g.pos() - jne_addr - 4) // 4 is for "00 00 00 00"
}

fn (mut g Gen) for_stmt(node ast.ForStmt) {
	infix_expr := node.cond as ast.InfixExpr
	// g.mov(.eax, 0x77777777)
	mut jump_addr := 0 // location of `jne *00 00 00 00*`
	start := g.pos()
	match infix_expr.left {
		ast.Ident {
			lit := infix_expr.right as ast.IntegerLiteral
			g.cmp_var(it.name, lit.val.int())
			jump_addr = g.jge()
		}
		else {
			verror('unhandled infix.left')
		}
	}
	g.stmts(node.stmts)
	// Go back to `cmp ...`
	// Diff between `jmp 00 00 00 00 X` and `cmp`
	g.jmp(0xffffffff - (g.pos() + 5 - start) + 1)
	// Update the jump addr to current pos
	g.write32_at(jump_addr, g.pos() - jump_addr - 4) // 4 is for "00 00 00 00"
	g.println('jpm after for')
}

fn (mut g Gen) fn_decl(node ast.FnDecl) {
	println(term.green('\n$node.name:'))
	g.stack_var_pos = 0
	is_main := node.name == 'main'
	// println('saving addr $node.name $g.buf.len.hex()')
	if is_main {
		g.save_main_fn_addr()
	} else {
		g.register_function_address(node.name)
	}
	g.push(.rbp)
	g.mov_rbp_rsp()
	if !is_main {
		g.sub32(.rsp, 0x20)
	}
	if node.args.len > 0 {
		// g.mov(.r12, 0x77777777)
	}
	// Copy values from registers to local vars (calling convention)
	mut offset := 0
	for i in 0 .. node.args.len {
		name := node.args[i].name
		// TODO optimize. Right now 2 mov's are used instead of 1.
		g.allocate_var(name, 4, 0)
		// `mov DWORD PTR [rbp-0x4],edi`
		offset += 4
		g.mov_from_reg(offset, fn_arg_registers[i])
	}
	//
	g.stmts(node.stmts)
	if is_main {
		// println('end of main: gen exit')
		g.gen_exit()
		// return
	}
	if !is_main {
		g.leave()
		// g.add(.rsp, 0x20)
		// g.pop(.rbp)
	}
	g.ret()
}

fn (mut g Gen) postfix_expr(node ast.PostfixExpr) {
	if !(node.expr is ast.Ident) {
		return
	}
	ident := node.expr as ast.Ident
	var_name := ident.name
	if node.op == .inc {
		g.inc_var(var_name)
	}
}

fn verror(s string) {
	util.verror('x64 gen error', s)
}
