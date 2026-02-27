use std::path::PathBuf;
use clap::{Parser, Subcommand};
use tracing_subscriber::EnvFilter;
use xdma_capture::{capture, CaptureConfig};

#[derive(Parser)]
#[command(name = "xdma_capture")]
#[command(about = "XDMA H2C/C2H capture (AXI-MM)")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    // Write payload to FPGA (H2C), read back (C2H), verify.
    Capture {
        // XDMA device id (e.g. xdma0)
        #[arg(long)]
        xid: String,

        // Channel index (assuming H2C and C2H are on the same channel)
        #[arg(long)]
        chan: u32,

        // Number of bytes to write and read back
        #[arg(long)]
        len: usize,

        // Input file: first LEN bytes used as write payload
        #[arg(long)]
        r#in: PathBuf,
    },
}

fn main() -> Result<(), anyhow::Error> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("xdma_capture=info".parse()?))
        .init();

    let cli = Cli::parse();
    match cli.command {
        Command::Capture {
            xid,
            chan,
            len,
            r#in: in_path,
        } => {
            let cfg = CaptureConfig {
                xid,
                chan,
                len,
                input_path: in_path,
            };
            capture(&cfg)?;
            tracing::info!("capture OK");
        }
    }
    Ok(())
}
