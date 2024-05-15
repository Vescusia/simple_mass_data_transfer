use clap::Parser;

mod server;
mod client;
mod cli;
mod ui;


fn main() -> anyhow::Result<()> {
    let args = std::env::args_os();
    if args.len() > 1 {
        let args = cli::Args::parse_from(args);
        println!("{args:?}");
        
        match args.action {
            cli::Action::Download{ .. } => {
                let (tx, rx) = std::sync::mpsc::channel();
                client::connect(args, tx)?
            },
            cli::Action::Host{ .. } => {
                server::serve(args)?
            }
        }
    }
    else {
        println!("GUI not yet supported! Please use -h to access the CLI-Help!");
        eframe::run_native(
            "SMD-Client", 
            eframe::NativeOptions::default(), 
            Box::new(|_cc| Box::<ui::client_ui::ClientUi>::default())
        ).expect("Could not create GUI.");
    }
    
    Ok(())
}