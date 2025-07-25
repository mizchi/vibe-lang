use dashmap::DashMap;
use ropey::Rope;
use tower_lsp::lsp_types::Url;

/// Manages text documents in memory
pub struct TextDocuments {
    documents: DashMap<Url, Rope>,
}

impl TextDocuments {
    pub fn new() -> Self {
        Self {
            documents: DashMap::new(),
        }
    }

    pub fn open(&self, uri: Url, text: String) {
        let rope = Rope::from_str(&text);
        self.documents.insert(uri, rope);
    }

    pub fn update(&self, uri: Url, text: String) {
        let rope = Rope::from_str(&text);
        self.documents.insert(uri, rope);
    }

    pub fn close(&self, uri: &Url) {
        self.documents.remove(uri);
    }

    pub fn get(&self, uri: &Url) -> Option<String> {
        self.documents.get(uri).map(|rope| rope.to_string())
    }

    pub fn get_rope(&self, uri: &Url) -> Option<dashmap::mapref::one::Ref<Url, Rope>> {
        self.documents.get(uri)
    }
}
