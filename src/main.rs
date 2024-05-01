use clap::Parser;

mod cli;
mod server;
mod client;


fn main() -> anyhow::Result<()> {
    let args = std::env::args_os();
    if args.len() > 1 {
        let args = cli::Args::parse_from(args);
        println!("{args:?}");
        
        match args.action {
            cli::Action::Download{ .. } => {
                client::connect(args)?
            },
            cli::Action::Host{ .. } => {
                server::serve(args)?
            }
        }
    }
    else {
        println!("GUI not yet supported! Please use -h to access the CLI-Help!")
    }
    
    Ok(())
}