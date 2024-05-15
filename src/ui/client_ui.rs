use simple_mass_data_transfer::event_handler::ClientEvent;
use crate::cli::Args;

use eframe::Frame;
use egui::Context;


#[derive(Debug)]
struct File {
	rel_path: String,
	downloaded_bytes: u64,
	total_bytes: u64
}


pub struct ClientUi {
    address: String,
    connected: Option<std::thread::JoinHandle<anyhow::Result<()>>>,
	path: Option<String>,
	encryption_key: String,
	compressed: bool,
	downloaded_bytes: u64,
	total_bytes: u64,
	bytes_per_sec: f32,
	event_stream: Option<std::sync::mpsc::Receiver<ClientEvent>>,
	dl_speed_timer: std::time::Instant,
	files: Vec<File>,
	popup: Vec<(String, bool)>
}


impl ClientUi {
	fn popup(&mut self, text: String) {
		self.popup.push((text, true))
	}
}


impl Default for ClientUi {
	fn default() -> Self {
		Self{
			address: "".to_string(),
			connected: None,
			path: None,
			encryption_key: "".to_string(),
			compressed: true,
			downloaded_bytes: 0,
			total_bytes: 0,
			bytes_per_sec: 0.,
			event_stream: None,
			dl_speed_timer: std::time::Instant::now(),
			files: Vec::new(),
			popup: Default::default()
		}
	}
}


impl eframe::App for ClientUi {
    fn update(&mut self, ctx: &Context, _frame: &mut Frame) {
		// display all popup messages
		for (text, open) in self.popup.iter_mut() {
			egui::Window::new("Alert")
				.collapsible(false)
				.resizable(true)
				.open(open)
				.show(ctx, |ui| {
					ui.vertical_centered(|ui| {
						ui.label(text.as_str())
					});
				});
		}
		self.popup.retain(|popup| popup.1);

		// handle events
		while let Some(recv) = &self.event_stream {
			if let Ok(event) = recv.try_recv() {
				match event {
					ClientEvent::FileUpdate(bytes_read) => {
						let bytes_read = bytes_read as u64;
						self.downloaded_bytes += bytes_read;
						let end = self.files.len() - 1;
						self.files[end].downloaded_bytes += bytes_read;
					},
					ClientEvent::FileHeader{rel_path, size} => {
						self.files.push(File{ rel_path, total_bytes: size, downloaded_bytes: 0 })
					},
					ClientEvent::FileFinished(hashes_match) => if !hashes_match {
						let _ = self.files.pop();
					} else {
						self.bytes_per_sec = self.files.last().unwrap().total_bytes as f32 / self.dl_speed_timer.elapsed().as_secs_f32();
						self.dl_speed_timer = std::time::Instant::now();
					},
					ClientEvent::Completed(time_taken) => {
						self.popup(
							format!("Download Completed in {time_taken:?} ({}/s)", bytesize::ByteSize(self.total_bytes / time_taken.as_secs()))
						)
					},
					ClientEvent::ResumeListFound(file_amount) => {
						self.popup(format!("Resume List found, containing {file_amount} hashes."))
					}
					ClientEvent::HandShakeResponse{ compression, total_size } => {
						if compression && !self.compressed {
							self.popup("Server is forcing compression.".into())
						}
						self.total_bytes = total_size;
					}
				}
			}
			else {
				break
			}
		}

		if self.connected.is_none() {
			egui::CentralPanel::default().show(ctx, |ui| {
				ui.heading("Connect to Server");
				ui.separator();
				
				// Address dialogue
				ui.add(egui::TextEdit::singleline(&mut self.address)
					.clip_text(false)
					.hint_text("Server Address"));

				// Select Download Directory Button
				let button = egui::Button::new(
					match self.path.as_ref() {
						Some(p) => {
							ui.label("Downloading to:");
							p.as_str()
						},
						None => "Select Download Directory"
					}
				);
				if ui.add(button).clicked() {
					self.path = tinyfiledialogs::select_folder_dialog("Select Download Directory", "");
				}
				
				ui.separator();
				
				// compression and encryption
				ui.checkbox(&mut self.compressed, "Compressed");
				ui.add(egui::TextEdit::singleline(&mut self.encryption_key)
					.password(true)
					.hint_text("Encryption Key")
				).on_hover_text("If the server is using encryption, please enter the key here.");
				ui.separator();
				
				// Connect Button
				let button = egui::Button::new(match (super::validate_socket_address(&self.address), self.path.is_some()) {
					(true, true) => "Connect",
					(false, true) => "Enter a valid Socket Address!",
					(true, false) => "Select a valid Download Path!",
					(false, false) => "Enter valid Socket Address Select and Download Path!"
				});
				// only enabled when address and path is some
				if ui.add_enabled(super::validate_socket_address(&self.address) && self.path.is_some(), button).clicked() {
					// build args
					let args = Args{
						action: crate::cli::Action::Download {
							address: self.address.clone(),
							path: self.path.as_ref().unwrap().clone(),
						},
						encryption_key: if self.encryption_key.is_empty() { None } else { Some(self.encryption_key.clone()) },
						compression: self.compressed,
					};
					// start download thread
					let (send, recv) = std::sync::mpsc::channel();
					let handle = std::thread::spawn(move || crate::client::connect(args, send));

					self.event_stream = Some(recv);
					self.connected = Some(handle);
				}
				});
		}
		else {
			// if handle is finished...
			if self.connected.as_ref().map_or(false, |h| h.is_finished()) {
				let handle = self.connected.take().unwrap();
				if let Err(e) = handle.join().expect("SMD-Thread panicked. This is a Bug. Please report your console output.") {
					self.popup(format!("SMD-Transfer encountered Error: {e:?}"));
					eprintln!("{e:?}")
				}
			}

			// show general info at top
			egui::TopBottomPanel::top("TopBar").show(ctx, |ui| {
				ui.columns(4, |columns| {
					columns[0].vertical_centered(|ui| {
						ui.label("Connected to:");
						ui.label(self.address.as_str());
					});

					columns[1].vertical_centered(|ui| {
						ui.label("Downloading to:");
						ui.label(self.path.as_ref().unwrap().as_str());
					});

					columns[2].vertical_centered(|ui| {
						ui.add_enabled(false, egui::Checkbox::new(&mut self.compressed, "Compressed"));
					});

					columns[3].vertical_centered(|ui| {
						ui.add_enabled(false, egui::Checkbox::new(&mut !self.encryption_key.is_empty(), "Encrypted"));
						ui.allocate_space(ui.available_size())
					});
				});
			});

			// progress bar and speed info at bottom
			egui::TopBottomPanel::bottom("ProgressBottom").show(ctx, |ui| {
				ui.horizontal(|ui| {
					ui.label(bytesize::ByteSize(self.downloaded_bytes).to_string());
					ui.label("out of");

					ui.label(bytesize::ByteSize(self.total_bytes).to_string());
					ui.separator();
					
					let mut bps = bytesize::ByteSize(self.bytes_per_sec as u64).to_string();
					bps.push_str("/s");
					ui.label(bps);
					ui.separator();
					
					ui.add(
						egui::ProgressBar::new((self.downloaded_bytes as f32) / (self.total_bytes as f32))
							.show_percentage()
							.animate(true)
					);
				});
			});

			// file list
			egui::CentralPanel::default().show(ctx, |ui| {
				let row_height = ui.text_style_height(&egui::TextStyle::Body) * 1.5;
				egui::ScrollArea::vertical()
					.stick_to_bottom(true)
					.show_rows(ui, row_height, self.files.len(), |ui, row_range| {
						for row in row_range {
							ui.horizontal(|ui| {
								ui.label(&self.files[row].rel_path);
								ui.with_layout(egui::Layout::right_to_left(egui::Align::TOP), |ui| {
									ui.label(format!("{}/{}",
											 bytesize::ByteSize(self.files[row].downloaded_bytes),
											 bytesize::ByteSize(self.files[row].total_bytes)));
								});
							});
							ui.add(
								egui::ProgressBar::new((self.files[row].downloaded_bytes as f32) / (self.files[row].total_bytes as f32))
									.fill(egui::Color32::from_hex("#008574").unwrap())
							);
							ui.add_space(ui.text_style_height(&egui::TextStyle::Body) / 2.)
						}
					});
			});
		}
    }
}