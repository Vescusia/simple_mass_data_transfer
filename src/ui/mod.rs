pub mod client_ui;
pub mod server_ui;


fn validate_socket_address(address: &str) -> bool {
    let re = regex::Regex::new(
        r"(([a-z]+\.)?[a-z]+(\.[a-z]+)?:[0-9]+)|([0-9]{3}\.[0-9]{3}\.[0-9]{3}\.[0-9]{3}:[0-9]+)"
    ).unwrap();
    
    match re.captures(address) {
        Some(c) => &c[0] == address,
        None => false
    }
}