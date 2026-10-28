#![deny(clippy::unwrap_used, clippy::expect_used)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used))]

//! Small test program: signs in and lists the movies.
//! Usage: cargo run -- [server_address]

use playfin_core::JellyfinClient;
use std::io::{self, Write};

#[tokio::main]
async fn main() {
    let server = std::env::args().nth(1).unwrap_or_else(|| {
        std::env::var("JF_TEST_URL").unwrap_or_else(|_| "http://localhost:8096".to_string())
    });

    print!("Username: ");
    if let Err(e) = io::stdout().flush() {
        eprintln!("stdout error: {e}");
        return;
    }
    let mut username = String::new();
    if let Err(e) = io::stdin().read_line(&mut username) {
        eprintln!("stdin error: {e}");
        return;
    }
    let password = match rpassword::prompt_password("Password: ") {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Could not read password: {e}");
            return;
        }
    };

    let client = JellyfinClient::new(&server, &std::env::temp_dir().to_string_lossy());
    if let Err(e) = client.login(username.trim(), &password).await {
        eprintln!("Sign-in failed: {e}");
        return;
    }

    match client.movies().await {
        Ok(movies) => {
            println!("\n{} movies:", movies.len());
            for movie in movies {
                let year = movie
                    .production_year
                    .map(|y| y.to_string())
                    .unwrap_or_default();
                let minutes = movie
                    .duration_minutes()
                    .map(|m| format!("{m} min"))
                    .unwrap_or_default();
                let container = movie.container.as_deref().unwrap_or("?");
                println!(
                    "  {:<50} {:>4}  {:>8}  [{container}]",
                    movie.name, year, minutes
                );
            }
        }
        Err(e) => eprintln!("Error: {e}"),
    }
}
