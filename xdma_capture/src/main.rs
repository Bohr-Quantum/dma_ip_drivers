use std::path::PathBuf;
use clap::{Parser, Subcommand};
use tracing_subscriber::EnvFilter;
use xdma_capture::{capture_to_file, loopback, parse_addr, CaptureConfig, LoopbackConfig};

#[derive(Parser)]
#[command(name = "xdma_capture")]
#[command(about = "XDMA H2C/C2H loopback and capture (AXI-MM)")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    // Write payload to FPGA (H2C), read back (C2H), verify.
    Loopback {
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

    // Read LEN bytes from C2H at ADDR and write to file (no H2C write).
    Capture {
        #[arg(long)]
        xid: String,

        #[arg(long)]
        chan: u32,

        #[arg(long)]
        addr: String,

        #[arg(long)]
        len: usize,

        #[arg(long)]
        out: PathBuf,
    },
}

fn main() -> Result<(), anyhow::Error> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("xdma_capture=info".parse()?))
        .init();

    let cli = Cli::parse();
    match cli.command {
        Command::Loopback {
            xid,
            chan,
            len,
            r#in: in_path,
        } => {
            let cfg = LoopbackConfig {
                xid,
                chan,
                len,
                input_path: in_path,
            };
            loopback(&cfg)?;
            tracing::info!("loopback OK");
        }
        Command::Capture {
            xid,
            chan,
            addr,
            len,
            out,
        } => {
            let addr = parse_addr(&addr).map_err(|e| anyhow::anyhow!("invalid addr: {}", e))?;
            let cfg = CaptureConfig {
                xid,
                chan,
                addr,
                len,
                out_path: out,
            };
            capture_to_file(&cfg)?;
            tracing::info!("capture OK");
        }
    }
    Ok(())
}
