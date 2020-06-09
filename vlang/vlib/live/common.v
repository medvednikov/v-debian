module live

pub type FNLinkLiveSymbols = fn (linkcb voidptr)

pub type FNLiveReloadCB = fn (info &LiveReloadInfo)

pub struct LiveReloadInfo {
pub:
	vexe              string // full path to the v compiler
	vopts             string // v compiler options for a live shared library
	original          string // full path to the original source file, compiled with -live
	live_fn_mutex     voidptr // the address of the C mutex, that locks the [live] fns during reloads.
	live_linkfn       FNLinkLiveSymbols // generated C callback; receives a dlopen handle
	so_extension      string // .so or .dll
	so_name_template  string // a sprintf template for the shared libraries location
pub mut:
	live_lib          voidptr // the result of dl.open
	reloads           int // how many times a reloading was tried
	reloads_ok        int // how many times the reloads succeeded
	reload_time_ms    int // how much time the last reload took (compilation + loading)
	last_mod_ts       int // a timestamp for when the original was last changed
	recheck_period_ms int = 100 // how often do you want to check for changes
	cb_recheck        FNLiveReloadCB = 0 // executed periodically
	cb_compile_failed FNLiveReloadCB = 0 // executed when a reload compilation failed
	cb_before         FNLiveReloadCB = 0 // executed before a reload try happens
	cb_after          FNLiveReloadCB = 0 // executed after a reload try happened, even if failed
	cb_locked_before  FNLiveReloadCB = 0 // executed before lib reload, in the mutex section
	cb_locked_after   FNLiveReloadCB = 0 // executed after lib reload, in the mutex section
}

// LiveReloadInfo.live_linkfn should be called by the reloader
// to dlsym all live functions. TODO: research a way to implement
// live_linkfn in pure V, without complicating live code generation
// too much.
//
// The callbacks: cb_compile_fail, cb_before, cb_after will be
// executed outside the mutex protected section, so be careful,
// if you modify your data inside them. They can race with your
// [live] functions.
//
// cb_locked_before and cb_locked_after will be executed *inside*
// the mutex protected section. They can NOT race with your [live]
// functions. They should be very quick in what they do though,
// otherwise your live functions can be delayed.
//
// live.info - give user access to program's LiveReloadInfo struct,
// so that the user can set callbacks, read meta information, etc.
pub fn info() &LiveReloadInfo {
	if C.g_live_info != 0 {
		return C.g_live_info
	}
	// When the current program is not compiled with -live, simply
	// return a new empty struct LiveReloadInfo in order to prevent
	// crashes. In this case, the background reloader thread is not
	// started, and the structure LiveReloadInfo will not get updated.
	// All its fields will be 0, but still safe to access.
	mut x := &LiveReloadInfo{}
	C.g_live_info = voidptr(x)
	return x
}
