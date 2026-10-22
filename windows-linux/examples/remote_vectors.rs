//! Prints a fixed key, its topics and a sealed message, to cross-check other implementations.
fn main() {
    let key_b64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
    let key = nocturnal::remote::parse_key(key_b64).unwrap();
    let (c, r) = nocturnal::remote::topics(&key);
    println!("cmd={c}\nreply={r}");
    println!(
        "sealed={}",
        nocturnal::remote::seal(&key, &c, "{\"cmd\":\"panel\",\"n\":\"abc\",\"t\":1}")
    );
    if let Some(m) = std::env::args().nth(1) {
        println!("opened={:?}", nocturnal::remote::open(&key, &r, &m));
    }
}
