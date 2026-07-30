wit_bindgen::generate!({
    path: "../wit",
    world: "probe",
    async: true,
});

struct MyGuest;

impl Guest for MyGuest {
    async fn run() -> u32 {
        get_async().await
    }
}

export!(MyGuest);
