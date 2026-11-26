//! Pure-Rust dynamic wrapper over LG webOS `libluna-service2.so` and `libglib-2.0.so`.

use std::collections::VecDeque;
use std::ffi::{CStr, CString, c_char, c_int, c_ulong, c_void};
use std::ptr::{null, null_mut};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::JoinHandle;

/// ABI-compatible `LSError` matching `luna-service2/lunaservice.h`.
#[repr(C)]
struct LsError {
    error_code: c_int,
    message: *mut c_char,
    file: *const c_char,
    line: c_int,
    func: *const c_char,
    padding: *mut c_void,
    magic: c_ulong,
}

impl LsError {
    fn zeroed() -> Self {
        Self {
            error_code: 0,
            message: null_mut(),
            file: null(),
            line: 0,
            func: null(),
            padding: null_mut(),
            magic: 0,
        }
    }
}

type LsFilterFunc = extern "C" fn(*mut c_void, *mut c_void, *mut c_void) -> bool;
type GSourceFunc = extern "C" fn(*mut c_void) -> c_int;
type GDestroyNotify = extern "C" fn(*mut c_void);

type LsErrorInitFn = unsafe extern "C" fn(*mut LsError) -> bool;
type LsErrorFreeFn = unsafe extern "C" fn(*mut LsError);
type LsRegisterFn = unsafe extern "C" fn(*const c_char, *mut *mut c_void, *mut LsError) -> bool;
type LsUnregisterFn = unsafe extern "C" fn(*mut c_void, *mut LsError) -> bool;
type LsGmainContextAttachFn = unsafe extern "C" fn(*mut c_void, *mut c_void, *mut LsError) -> bool;
type LsCallFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const c_char,
    LsFilterFunc,
    *mut c_void,
    *mut c_ulong,
    *mut LsError,
) -> bool;
type LsCallOneReplyFn = LsCallFn;
/// `LSCallFromApplication[OneReply]`: same as `LSCall` plus an `applicationID` argument,
/// so the call is made on behalf of the app (what PlxNative uses for `com.webos.media`).
type LsCallFromAppFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const c_char,
    *const c_char,
    LsFilterFunc,
    *mut c_void,
    *mut c_ulong,
    *mut LsError,
) -> bool;
type LsCallCancelFn = unsafe extern "C" fn(*mut c_void, c_ulong, *mut LsError) -> bool;
type LsMessageGetPayloadFn = unsafe extern "C" fn(*mut c_void) -> *const c_char;

type GMainContextNewFn = unsafe extern "C" fn() -> *mut c_void;
type GMainContextUnrefFn = unsafe extern "C" fn(*mut c_void);
type GMainContextInvokeFullFn =
    unsafe extern "C" fn(*mut c_void, c_int, GSourceFunc, *mut c_void, GDestroyNotify);
type GMainLoopNewFn = unsafe extern "C" fn(*mut c_void, c_int) -> *mut c_void;
type GMainLoopRunFn = unsafe extern "C" fn(*mut c_void);
type GMainLoopQuitFn = unsafe extern "C" fn(*mut c_void);
type GMainLoopUnrefFn = unsafe extern "C" fn(*mut c_void);

struct RawLib(*mut c_void);
// SAFETY: Shared library dlopen handles are immutable pointers closed once on Drop.
unsafe impl Send for RawLib {}
// SAFETY: Shared library dlopen handles can be inspected from any thread cleanly.
unsafe impl Sync for RawLib {}

impl Drop for RawLib {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: Handle opened by `dlopen` in `open_first`.
            unsafe {
                libc::dlclose(self.0);
            }
        }
    }
}

struct LunaApi {
    _glib: RawLib,
    _ls2: RawLib,
    ls_error_init: LsErrorInitFn,
    ls_error_free: LsErrorFreeFn,
    ls_register: LsRegisterFn,
    ls_unregister: LsUnregisterFn,
    ls_gmain_context_attach: LsGmainContextAttachFn,
    ls_call: LsCallFn,
    ls_call_one_reply: LsCallOneReplyFn,
    ls_call_cancel: LsCallCancelFn,
    ls_call_from_app: Option<LsCallFromAppFn>,
    ls_call_from_app_one_reply: Option<LsCallFromAppFn>,
    ls_message_get_payload: LsMessageGetPayloadFn,
    g_main_context_new: GMainContextNewFn,
    g_main_context_unref: GMainContextUnrefFn,
    g_main_context_invoke_full: GMainContextInvokeFullFn,
    g_main_loop_new: GMainLoopNewFn,
    g_main_loop_run: GMainLoopRunFn,
    g_main_loop_quit: GMainLoopQuitFn,
    g_main_loop_unref: GMainLoopUnrefFn,
}

unsafe fn open_first(candidates: &[&CStr]) -> Option<RawLib> {
    for name in candidates {
        // SAFETY: `name` is static NUL-terminated; `RTLD_NOW | RTLD_GLOBAL` loads C symbols cleanly.
        let handle = unsafe { libc::dlopen(name.as_ptr(), libc::RTLD_NOW | libc::RTLD_GLOBAL) };
        if !handle.is_null() {
            return Some(RawLib(handle));
        }
    }
    None
}

unsafe fn resolve_fn<F: Copy>(lib: &RawLib, name: &CStr) -> Result<F, String> {
    // SAFETY: Caller provides a `Copy` function pointer matching the C prototype of `name`.
    unsafe {
        let ptr = libc::dlsym(lib.0, name.as_ptr());
        if ptr.is_null() {
            return Err(format!("missing symbol {}", name.to_string_lossy()));
        }
        Ok(std::mem::transmute_copy::<*mut c_void, F>(&ptr))
    }
}

impl LunaApi {
    fn load() -> Result<Self, String> {
        // SAFETY: Both shared libraries use stable C ABIs when present on LG webOS targets.
        unsafe {
            let glib = open_first(&[c"libglib-2.0.so.0", c"libglib-2.0.so"])
                .ok_or_else(|| "libglib-2.0 unavailable on host".to_string())?;
            let ls2 = open_first(&[c"libluna-service2.so.3", c"libluna-service2.so"])
                .ok_or_else(|| "libluna-service2 unavailable on host".to_string())?;

            Ok(Self {
                ls_error_init: resolve_fn::<LsErrorInitFn>(&ls2, c"LSErrorInit")?,
                ls_error_free: resolve_fn::<LsErrorFreeFn>(&ls2, c"LSErrorFree")?,
                ls_register: resolve_fn::<LsRegisterFn>(&ls2, c"LSRegister")?,
                ls_unregister: resolve_fn::<LsUnregisterFn>(&ls2, c"LSUnregister")?,
                ls_gmain_context_attach: resolve_fn::<LsGmainContextAttachFn>(
                    &ls2,
                    c"LSGmainContextAttach",
                )?,
                ls_call: resolve_fn::<LsCallFn>(&ls2, c"LSCall")?,
                ls_call_one_reply: resolve_fn::<LsCallOneReplyFn>(&ls2, c"LSCallOneReply")?,
                ls_call_cancel: resolve_fn::<LsCallCancelFn>(&ls2, c"LSCallCancel")?,
                ls_call_from_app: resolve_fn::<LsCallFromAppFn>(&ls2, c"LSCallFromApplication")
                    .ok(),
                ls_call_from_app_one_reply: resolve_fn::<LsCallFromAppFn>(
                    &ls2,
                    c"LSCallFromApplicationOneReply",
                )
                .ok(),
                ls_message_get_payload: resolve_fn::<LsMessageGetPayloadFn>(
                    &ls2,
                    c"LSMessageGetPayload",
                )?,
                g_main_context_new: resolve_fn::<GMainContextNewFn>(&glib, c"g_main_context_new")?,
                g_main_context_unref: resolve_fn::<GMainContextUnrefFn>(
                    &glib,
                    c"g_main_context_unref",
                )?,
                g_main_context_invoke_full: resolve_fn::<GMainContextInvokeFullFn>(
                    &glib,
                    c"g_main_context_invoke_full",
                )?,
                g_main_loop_new: resolve_fn::<GMainLoopNewFn>(&glib, c"g_main_loop_new")?,
                g_main_loop_run: resolve_fn::<GMainLoopRunFn>(&glib, c"g_main_loop_run")?,
                g_main_loop_quit: resolve_fn::<GMainLoopQuitFn>(&glib, c"g_main_loop_quit")?,
                g_main_loop_unref: resolve_fn::<GMainLoopUnrefFn>(&glib, c"g_main_loop_unref")?,
                _glib: glib,
                _ls2: ls2,
            })
        }
    }

    fn take_ls_error(&self, err: &mut LsError) -> String {
        let msg = if !err.message.is_null() {
            // SAFETY: Non-null NUL-terminated error message populated by `luna-service2`.
            unsafe { CStr::from_ptr(err.message) }
                .to_string_lossy()
                .into_owned()
        } else {
            format!("LSError code {}", err.error_code)
        };
        // SAFETY: `err` was initialized via `ls_error_init`.
        unsafe {
            (self.ls_error_free)(err);
        }
        msg
    }
}

/// Probes whether Luna Bus (`libluna-service2` + `libglib-2.0`) can load on this machine.
pub fn probe_runtime() -> Result<String, String> {
    let _api = LunaApi::load()?;
    Ok("libluna-service2 + libglib-2.0 OK".to_string())
}

/// Raw JSON message delivered asynchronously from Luna Bus on a dedicated `GMainContext` thread.
#[derive(Debug, Clone)]
pub struct LunaMessage {
    pub uri: String,
    pub payload: String,
    pub is_subscription: bool,
    pub tag: u64,
}

enum BusOp {
    Call {
        uri: String,
        payload: String,
        subscribe: bool,
        tag: u64,
    },
    CancelSubscriptions,
    Shutdown,
}

struct SendPtr(*mut c_void);
// SAFETY: `GMainContext` is GLib thread-safe for `g_main_context_invoke_full`.
unsafe impl Send for SendPtr {}

struct BusWorkerState {
    api: Arc<LunaApi>,
    ctx: Option<SendPtr>,
    mloop: Option<SendPtr>,
    ls_handle: Option<SendPtr>,
    queue: VecDeque<BusOp>,
    callback_ctx: *mut c_void,
    /// When set (and the TV exports it), calls go through `LSCallFromApplication*` with this id.
    app_id: Option<CString>,
}
// SAFETY: Synchronized via `Arc<Mutex<BusWorkerState>>`; GLib pointers are freed strictly on worker thread.
unsafe impl Send for BusWorkerState {}

struct OwnedCallCtx(*mut CallUserCtx);
impl Drop for OwnedCallCtx {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: Reclaimed only on the GLib thread after unregister/cancel or one-shot reply.
            unsafe {
                drop(Box::from_raw(self.0));
            }
        }
    }
}

struct CallbackRouter {
    api: Arc<LunaApi>,
    tx: mpsc::Sender<LunaMessage>,
    next_id: u64,
    subscriptions: Vec<(c_ulong, OwnedCallCtx)>,
    one_shots: Vec<(u64, OwnedCallCtx)>,
}

struct CallUserCtx {
    router: *mut CallbackRouter,
    id: u64,
    uri: String,
    subscribe: bool,
    tag: u64,
}

extern "C" fn luna_msg_cb(_sh: *mut c_void, msg: *mut c_void, user_data: *mut c_void) -> bool {
    if user_data.is_null() || msg.is_null() {
        return true;
    }
    let (router_ptr, ctx_id, uri, subscribe, tag, api, payload) = {
        // SAFETY: `user_data` points to `CallUserCtx` owned by `CallbackRouter` until removed below.
        let ctx = unsafe { &*(user_data as *const CallUserCtx) };
        let router_ptr = ctx.router;
        // SAFETY: `router_ptr` stays valid on GLib thread until after `LSUnregister` finishes.
        let router = unsafe { &*router_ptr };
        // SAFETY: `msg` is valid for the duration of this LS2 callback.
        let payload_ptr = unsafe { (router.api.ls_message_get_payload)(msg) };
        let payload = if payload_ptr.is_null() {
            "{}".to_string()
        } else {
            // SAFETY: `LSMessageGetPayload` returns a NUL-terminated JSON string.
            unsafe { CStr::from_ptr(payload_ptr) }
                .to_string_lossy()
                .into_owned()
        };
        (
            router_ptr,
            ctx.id,
            ctx.uri.clone(),
            ctx.subscribe,
            ctx.tag,
            router.api.clone(),
            payload,
        )
    };

    // SAFETY: Exclusive GLib-thread access; borrow on `CallUserCtx` already ended above.
    unsafe {
        let _ = &api;
        let _ = (*router_ptr).tx.send(LunaMessage {
            uri,
            payload,
            is_subscription: subscribe,
            tag,
        });
        if !subscribe {
            (*router_ptr).one_shots.retain(|(id, _)| *id != ctx_id);
        }
    }
    true
}

extern "C" fn drop_arc_state(data: *mut c_void) {
    if !data.is_null() {
        // SAFETY: Balances `Arc::into_raw` in `LunaClient::enqueue`.
        unsafe {
            drop(Arc::from_raw(data as *const Mutex<BusWorkerState>));
        }
    }
}

fn cancel_all_subscriptions(api: &LunaApi, handle: *mut c_void, router_ptr: *mut CallbackRouter) {
    if handle.is_null() || router_ptr.is_null() {
        return;
    }
    // SAFETY: Called exclusively on the GLib thread with valid `LSHandle` and `CallbackRouter`.
    unsafe {
        let mut lserr = LsError::zeroed();
        for (token, ctx) in (*router_ptr).subscriptions.drain(..) {
            (api.ls_error_init)(&mut lserr);
            let _ = (api.ls_call_cancel)(handle, token, &mut lserr);
            (api.ls_error_free)(&mut lserr);
            drop(ctx);
        }
    }
}

extern "C" fn drain_ops_cb(data: *mut c_void) -> c_int {
    if data.is_null() {
        return 0;
    }
    // SAFETY: Borrowed until `drop_arc_state` runs immediately after returning `0`.
    let state_ref = unsafe { &*(data as *const Mutex<BusWorkerState>) };
    let ops: Vec<BusOp>;
    let (api, handle, mloop, router_ptr, app_id) = {
        let Ok(mut guard) = state_ref.lock() else {
            return 0;
        };
        ops = guard.queue.drain(..).collect();
        (
            guard.api.clone(),
            guard.ls_handle.as_ref().map(|p| p.0).unwrap_or(null_mut()),
            guard.mloop.as_ref().map(|p| p.0).unwrap_or(null_mut()),
            guard.callback_ctx as *mut CallbackRouter,
            guard.app_id.clone(),
        )
    };

    for op in ops {
        match op {
            BusOp::Call {
                uri,
                payload,
                subscribe,
                tag,
            } => {
                if handle.is_null() || router_ptr.is_null() {
                    continue;
                }
                let Ok(c_uri) = CString::new(uri.as_str()) else {
                    continue;
                };
                let Ok(c_payload) = CString::new(payload.as_str()) else {
                    continue;
                };
                // SAFETY: Exclusive GLib-thread access to `CallbackRouter`.
                let call_id = unsafe {
                    (*router_ptr).next_id += 1;
                    (*router_ptr).next_id
                };
                let call_ctx = Box::into_raw(Box::new(CallUserCtx {
                    router: router_ptr,
                    id: call_id,
                    uri: uri.clone(),
                    subscribe,
                    tag,
                }));

                let mut lserr = LsError::zeroed();
                let mut token: c_ulong = 0;
                // SAFETY: Valid `LSHandle`, `LSError`, and NUL-terminated C strings.
                unsafe {
                    (api.ls_error_init)(&mut lserr);
                    let from_app = if subscribe {
                        api.ls_call_from_app
                    } else {
                        api.ls_call_from_app_one_reply
                    };
                    let ok = if let (Some(call_fn), Some(id)) = (from_app, app_id.as_ref()) {
                        call_fn(
                            handle,
                            c_uri.as_ptr(),
                            c_payload.as_ptr(),
                            id.as_ptr(),
                            luna_msg_cb,
                            call_ctx as *mut c_void,
                            &mut token,
                            &mut lserr,
                        )
                    } else if subscribe {
                        (api.ls_call)(
                            handle,
                            c_uri.as_ptr(),
                            c_payload.as_ptr(),
                            luna_msg_cb,
                            call_ctx as *mut c_void,
                            &mut token,
                            &mut lserr,
                        )
                    } else {
                        (api.ls_call_one_reply)(
                            handle,
                            c_uri.as_ptr(),
                            c_payload.as_ptr(),
                            luna_msg_cb,
                            call_ctx as *mut c_void,
                            &mut token,
                            &mut lserr,
                        )
                    };
                    if !ok {
                        let msg = api.take_ls_error(&mut lserr);
                        drop(OwnedCallCtx(call_ctx));
                        let _ = (*router_ptr).tx.send(LunaMessage {
                            uri,
                            payload: serde_json::json!({ "returnValue": false, "errorText": msg })
                                .to_string(),
                            is_subscription: subscribe,
                            tag,
                        });
                    } else {
                        (api.ls_error_free)(&mut lserr);
                        if subscribe {
                            (*router_ptr)
                                .subscriptions
                                .push((token, OwnedCallCtx(call_ctx)));
                        } else {
                            (*router_ptr)
                                .one_shots
                                .push((call_id, OwnedCallCtx(call_ctx)));
                        }
                    }
                }
            }
            BusOp::CancelSubscriptions => {
                cancel_all_subscriptions(&api, handle, router_ptr);
            }
            BusOp::Shutdown => {
                cancel_all_subscriptions(&api, handle, router_ptr);
                if !mloop.is_null() {
                    // SAFETY: Called on GLib loop thread with active `GMainLoop`.
                    unsafe {
                        (api.g_main_loop_quit)(mloop);
                    }
                }
            }
        }
    }

    0
}

/// Asynchronous client connected to LG webOS Luna Bus (`com.webos.media`, etc.).
pub struct LunaClient {
    registration_shape: String,
    state: Arc<Mutex<BusWorkerState>>,
    worker: Option<JoinHandle<()>>,
}

impl LunaClient {
    /// Connects to the Luna Bus (trying named `app_id` first, falling back to anonymous).
    pub fn connect(app_id: Option<&str>) -> Result<(Self, mpsc::Receiver<LunaMessage>), String> {
        let api = Arc::new(LunaApi::load()?);
        let (msg_tx, msg_rx) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<String, String>>();
        let app_id_owned = app_id.map(str::to_string);

        let state = Arc::new(Mutex::new(BusWorkerState {
            api: api.clone(),
            ctx: None,
            mloop: None,
            ls_handle: None,
            queue: VecDeque::new(),
            callback_ctx: null_mut(),
            app_id: app_id.and_then(|s| CString::new(s).ok()),
        }));

        let state_thread = state.clone();
        let worker = std::thread::spawn(move || {
            let mut lserr = LsError::zeroed();
            // SAFETY: GLib context + loop lifecycle confined cleanly to this worker thread.
            let (ctx, mloop) = unsafe {
                let c = (api.g_main_context_new)();
                let l = (api.g_main_loop_new)(c, 0);
                (c, l)
            };
            if ctx.is_null() || mloop.is_null() {
                let _ = ready_tx.send(Err("g_main_context_new / g_main_loop_new failed".into()));
                return;
            }

            let mut handle: *mut c_void = null_mut();
            let mut shape = String::from("anon");
            // Named candidates: the app id, then `<app id>-<pid>`. Each failure is kept for the log.
            let candidates: Vec<String> = app_id_owned
                .as_deref()
                .map(|id| vec![id.to_string(), format!("{id}-{}", std::process::id())])
                .unwrap_or_default();
            let mut failures: Vec<String> = Vec::new();
            // SAFETY: Tries named registration first, then anonymous.
            let registered = unsafe {
                (api.ls_error_init)(&mut lserr);
                let mut ok = false;
                for name in &candidates {
                    let Ok(c_name) = CString::new(name.as_str()) else {
                        continue;
                    };
                    ok = (api.ls_register)(c_name.as_ptr(), &mut handle, &mut lserr);
                    if ok {
                        shape = format!("named {name}");
                        break;
                    }
                    failures.push(format!("{name}: {}", api.take_ls_error(&mut lserr)));
                    (api.ls_error_init)(&mut lserr);
                }
                if !failures.is_empty() {
                    eprintln!(
                        "[playfin_webos] LSRegister named failed: {}",
                        failures.join(" | ")
                    );
                }
                if !ok {
                    ok = (api.ls_register)(null(), &mut handle, &mut lserr);
                }
                if !ok {
                    let msg = api.take_ls_error(&mut lserr);
                    let _ = ready_tx.send(Err(format!("LSRegister failed: {msg}")));
                    false
                } else {
                    (api.ls_error_free)(&mut lserr);
                    true
                }
            };

            if !registered || handle.is_null() {
                // SAFETY: Release GLib loop/context on registration error.
                unsafe {
                    (api.g_main_loop_unref)(mloop);
                    (api.g_main_context_unref)(ctx);
                }
                return;
            }

            // SAFETY: Attach `handle` to private `GMainContext` before running loop.
            let attached = unsafe {
                (api.ls_error_init)(&mut lserr);
                let ok = (api.ls_gmain_context_attach)(handle, ctx, &mut lserr);
                if !ok {
                    let msg = api.take_ls_error(&mut lserr);
                    let _ = ready_tx.send(Err(format!("LSGmainContextAttach failed: {msg}")));
                    false
                } else {
                    (api.ls_error_free)(&mut lserr);
                    true
                }
            };

            if !attached {
                // SAFETY: Roll back handle and GLib objects on attach failure.
                unsafe {
                    (api.ls_error_init)(&mut lserr);
                    let _ = (api.ls_unregister)(handle, &mut lserr);
                    (api.ls_error_free)(&mut lserr);
                    (api.g_main_loop_unref)(mloop);
                    (api.g_main_context_unref)(ctx);
                }
                return;
            }

            let router_ptr = Box::into_raw(Box::new(CallbackRouter {
                api: api.clone(),
                tx: msg_tx,
                next_id: 0,
                subscriptions: Vec::new(),
                one_shots: Vec::new(),
            }));

            if let Ok(mut guard) = state_thread.lock() {
                guard.ctx = Some(SendPtr(ctx));
                guard.mloop = Some(SendPtr(mloop));
                guard.ls_handle = Some(SendPtr(handle));
                guard.callback_ctx = router_ptr as *mut c_void;
            }

            if app_id_owned.is_some() && api.ls_call_from_app.is_some() {
                shape.push_str(" + callFromApp");
            }
            let _ = ready_tx.send(Ok(shape));

            // SAFETY: Runs until `g_main_loop_quit` on shutdown; frees router/calls after `LSUnregister`.
            unsafe {
                (api.g_main_loop_run)(mloop);
                (api.ls_error_init)(&mut lserr);
                let _ = (api.ls_unregister)(handle, &mut lserr);
                (api.ls_error_free)(&mut lserr);
                (api.g_main_loop_unref)(mloop);
                (api.g_main_context_unref)(ctx);
                drop(Box::from_raw(router_ptr));
            }
        });

        let shape = ready_rx
            .recv()
            .map_err(|_| "Luna worker thread exited prematurely".to_string())??;

        Ok((
            Self {
                registration_shape: shape,
                state,
                worker: Some(worker),
            },
            msg_rx,
        ))
    }

    pub fn registration_shape(&self) -> &str {
        &self.registration_shape
    }

    /// Enqueues a single-reply Luna Bus call (`LSCallOneReply`) with a caller correlation tag.
    pub fn call_once(&self, uri: &str, payload: &str, tag: u64) -> Result<(), String> {
        self.enqueue(BusOp::Call {
            uri: uri.to_string(),
            payload: payload.to_string(),
            subscribe: false,
            tag,
        })
    }

    /// Enqueues a persistent subscription call (`LSCall`) with a caller correlation tag.
    pub fn subscribe(&self, uri: &str, payload: &str, tag: u64) -> Result<(), String> {
        self.enqueue(BusOp::Call {
            uri: uri.to_string(),
            payload: payload.to_string(),
            subscribe: true,
            tag,
        })
    }

    /// Cancels all active Luna Bus subscriptions cleanly via `LSCallCancel`.
    pub fn cancel_subscriptions(&self) -> Result<(), String> {
        self.enqueue(BusOp::CancelSubscriptions)
    }

    fn enqueue(&self, op: BusOp) -> Result<(), String> {
        let (api, raw_ctx) = {
            let mut guard = self
                .state
                .lock()
                .map_err(|_| "Luna state lock poisoned".to_string())?;
            let Some(ctx) = guard.ctx.as_ref().map(|p| p.0) else {
                return Err("Luna bus is closed".to_string());
            };
            guard.queue.push_back(op);
            (guard.api.clone(), ctx)
        };

        let raw_state = Arc::into_raw(self.state.clone()) as *mut c_void;
        // SAFETY: `raw_ctx` stays valid until `worker.join()` in `Drop` after `guard.ctx` is cleared.
        unsafe {
            (api.g_main_context_invoke_full)(raw_ctx, 0, drain_ops_cb, raw_state, drop_arc_state);
        }
        Ok(())
    }
}

impl Drop for LunaClient {
    fn drop(&mut self) {
        let shutdown_ctx = if let Ok(mut guard) = self.state.lock() {
            guard.queue.push_back(BusOp::Shutdown);
            let ctx = guard.ctx.take();
            ctx.map(|p| (guard.api.clone(), p.0))
        } else {
            None
        };

        if let Some((api, raw_ctx)) = shutdown_ctx {
            let raw_state = Arc::into_raw(self.state.clone()) as *mut c_void;
            // SAFETY: `raw_ctx` remains alive until `worker.join()` completes below.
            unsafe {
                (api.g_main_context_invoke_full)(
                    raw_ctx,
                    0,
                    drain_ops_cb,
                    raw_state,
                    drop_arc_state,
                );
            }
        }

        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ls_error_has_expected_abi_field_count_and_probe_never_panics() {
        let err = LsError::zeroed();
        assert_eq!(err.error_code, 0);
        let _ = probe_runtime();
        let res = LunaClient::connect(Some("com.playfin.webos"));
        if cfg!(target_os = "macos") {
            assert!(res.is_err());
        }
    }
}
