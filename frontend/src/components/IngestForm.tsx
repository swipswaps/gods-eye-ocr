import React, { useState } from 'react';
import { Button, TextField, Alert, Paper, Typography } from '@mui/material';
import { ingestDocument } from '../services/api';
import useBackendStore from '../stores/backendStore';

const IngestForm: React.FC = () => {
  const [title, setTitle] = useState('');
  const [content, setContent] = useState('');
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<string | null>(null);
  const { status } = useBackendStore();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!title || !content) return;
    setLoading(true);
    setResult(null);
    try {
      const resp = await ingestDocument(title, content);
      setResult(`Ingested with ID: ${resp.data.id}`);
      setTitle('');
      setContent('');
    } catch (err) {
      setResult(`Error: ${err instanceof Error ? err.message : String(err)}`);
    } finally {
      setLoading(false);
    }
  };

  return (
    <Paper sx={{ p: 2, mb: 3 }}>
      <Typography variant="h6">Add Document to RAG</Typography>
      <form onSubmit={handleSubmit}>
        <TextField
          label="Title"
          fullWidth
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          disabled={status !== 'ok' || loading}
          margin="normal"
        />
        <TextField
          label="Content"
          fullWidth
          multiline
          rows={4}
          value={content}
          onChange={(e) => setContent(e.target.value)}
          disabled={status !== 'ok' || loading}
          margin="normal"
        />
        <Button type="submit" variant="contained" disabled={status !== 'ok' || loading}>
          Ingest
        </Button>
        {loading && <span>Loading...</span>}
        {result && (
          <Alert severity={result.startsWith('Error') ? 'error' : 'success'} sx={{ mt: 1 }}>
            {result}
          </Alert>
        )}
      </form>
    </Paper>
  );
};

export default IngestForm;
