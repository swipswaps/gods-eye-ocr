import React, { useState } from 'react';
import { Button, TextField, Box, Alert, Paper, Typography, List, ListItem, ListItemText } from '@mui/material';
import { queryRAG } from '../services/api';
import useBackendStore from '../stores/backendStore';

interface Result {
  id: number;
  title: string;
  content: string;
  distance: number;
}

const QueryForm: React.FC = () => {
  const [query, setQuery] = useState('');
  const [loading, setLoading] = useState(false);
  const [results, setResults] = useState<Result[]>([]);
  const [error, setError] = useState<string | null>(null);
  const { status } = useBackendStore();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!query) return;
    setLoading(true);
    setError(null);
    try {
      const resp = await queryRAG(query);
      setResults(resp.data.results);
    } catch (err: any) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <Paper sx={{ p: 2 }}>
      <Typography variant="h6">Query RAG</Typography>
      <form onSubmit={handleSubmit}>
        <TextField
          label="Ask a question"
          fullWidth
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          disabled={status !== 'ok' || loading}
          margin="normal"
        />
        <Button type="submit" variant="contained" disabled={status !== 'ok' || loading}>
          Search
        </Button>
        {loading && <span>Loading...</span>}
        {error && <Alert severity="error" sx={{ mt: 1 }}>{error}</Alert>}
        {results.length > 0 && (
          <List>
            {results.map((r) => (
              <ListItem key={r.id} divider>
                <ListItemText primary={r.title} secondary={`${r.content.substring(0, 150)}... (distance: ${r.distance.toFixed(4)})`} />
              </ListItem>
            ))}
          </List>
        )}
      </form>
    </Paper>
  );
};

export default QueryForm;
