// std smoke test for aarch64-unknown-haiku: each check prints ok/FAIL.
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn check(name: &str, r: Result<String, String>) -> bool {
    match r {
        Ok(detail) => { println!("ok    {name}: {detail}"); true }
        Err(e) => { println!("FAIL  {name}: {e}"); false }
    }
}

fn main() {
    let mut pass = 0;
    let mut total = 0;
    let mut run = |name: &str, f: &dyn Fn() -> Result<String, String>| {
        total += 1;
        if check(name, f()) { pass += 1; }
    };

    run("platform", &|| Ok(format!("{} {} {}", std::env::consts::OS, std::env::consts::ARCH, std::env::consts::FAMILY)));

    run("threads", &|| {
        let counter = Arc::new(Mutex::new(0u64));
        let hs: Vec<_> = (0..8).map(|i| {
            let c = Arc::clone(&counter);
            std::thread::spawn(move || { for _ in 0..1000 { *c.lock().unwrap() += 1; } i })
        }).collect();
        let ids: u64 = hs.into_iter().map(|h| h.join().unwrap()).sum();
        let n = *counter.lock().unwrap();
        if n == 8000 && ids == 28 { Ok(format!("8 threads, counter={n}")) } else { Err(format!("counter={n}")) }
    });

    run("hashmap", &|| {
        let m: HashMap<u32, u32> = (0..10_000).map(|i| (i, i * i)).collect();
        if m[&9999] == 9999 * 9999 { Ok(format!("{} entries", m.len())) } else { Err("bad value".into()) }
    });

    run("fs + File::lock", &|| {
        let dir = std::env::temp_dir().join(format!("stdcheck-{}", std::process::id()));
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let p = dir.join("f.txt");
        File::create(&p).and_then(|mut f| f.write_all(b"haiku")).map_err(|e| e.to_string())?;
        let mut s = String::new();
        File::open(&p).and_then(|mut f| f.read_to_string(&mut s)).map_err(|e| e.to_string())?;
        let f = File::open(&p).map_err(|e| e.to_string())?;
        let lock = f.lock().map_err(|e| format!("lock(): {e} ({:?})", e.kind()))?;
        let _ = lock;
        f.unlock().map_err(|e| format!("unlock(): {e}"))?;
        fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
        if s == "haiku" { Ok(format!("read back {s:?}, flock ok")) } else { Err(format!("read {s:?}")) }
    });

    run("tcp", &|| {
        let mut s = TcpStream::connect("example.com:80").map_err(|e| e.to_string())?;
        s.set_read_timeout(Some(Duration::from_secs(10))).map_err(|e| e.to_string())?;
        s.write_all(b"HEAD / HTTP/1.0\r\nHost: example.com\r\n\r\n").map_err(|e| e.to_string())?;
        let mut buf = [0u8; 64];
        let n = s.read(&mut buf).map_err(|e| e.to_string())?;
        let line = String::from_utf8_lossy(&buf[..n]).lines().next().unwrap_or("").to_string();
        if line.starts_with("HTTP/") { Ok(line) } else { Err(line) }
    });

    run("process", &|| {
        let out = Command::new("uname").arg("-m").output().map_err(|e| e.to_string())?;
        Ok(format!("uname -m -> {}", String::from_utf8_lossy(&out.stdout).trim()))
    });

    run("env + time", &|| {
        let home = std::env::var("HOME").unwrap_or_default();
        let t0 = Instant::now();
        std::thread::sleep(Duration::from_millis(50));
        let secs = SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e| e.to_string())?.as_secs();
        Ok(format!("HOME={home}, slept {:?}, unix={secs}", t0.elapsed()))
    });

    run("panic catch", &|| {
        let r = std::panic::catch_unwind(|| panic!("boom"));
        if r.is_err() { Ok("unwinding works".into()) } else { Err("no panic".into()) }
    });

    println!("{pass}/{total} passed");
    std::process::exit(if pass == total { 0 } else { 1 });
}
