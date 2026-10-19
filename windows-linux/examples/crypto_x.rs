//! Cross-implementation check: `crypto_x <key> topics | seal <topic> <text> | open <topic> <message>`.
fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    let key = ajar::remote::parse_key(&a[0]).expect("bad key");
    match a[1].as_str() {
        "topics" => { let (c, r) = ajar::remote::topics(&key); println!("{c} {r}"); }
        "seal" => println!("{}", ajar::remote::seal(&key, &a[2], &a[3])),
        "open" => println!("{}", ajar::remote::open(&key, &a[2], &a[3]).unwrap_or_else(|| "REJECTED".into())),
        _ => panic!("unknown"),
    }
}
