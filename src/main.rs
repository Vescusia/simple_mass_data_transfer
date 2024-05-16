use clap::Parser;

mod server;
mod client;
mod cli;
#[cfg(feature = "gui")]
mod ui;


fn main() -> anyhow::Result<()> {
    let args = std::env::args_os();
    if args.len() > 1 {
        let args = cli::Args::parse_from(args);
        
        match args.action {
            cli::Action::Download{ .. } => {
                let (tx, rx) = std::sync::mpsc::channel();
                // start printing thread
                let handle = std::thread::spawn(|| simple_mass_data_transfer::client_events::handle_events_cli(rx));
                // connect
                client::connect(args, tx)?;
                handle.join().expect("CLI-Handler panicked, please report bug.")?;
            },
            cli::Action::Host{ .. } => {
                server::serve(args)?
            }
        }
    }
    else {
        #[cfg(feature = "gui")]
        {
            println!("Starting Client-GUI. To use CLI, please add arguments (--help)");
            eframe::run_native(
                "SMD-Client",
                eframe::NativeOptions::default(),
                Box::new(|_cc| Box::<ui::ClientUi>::default())
            ).expect("Could not create GUI.");
        }
        #[cfg(not(feature = "gui"))]
        println!("Client-GUI Feature not enabled. Please add at least one argument! (--help)");
    }
    
    Ok(())
}
