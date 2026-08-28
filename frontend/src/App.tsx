import { useEffect } from 'react';
import { Container, Typography, Box, Paper, Alert } from '@mui/material';
import useBackendStore from './stores/backendStore';
import { checkBackend } from './services/api';
import StatusIndicator from './components/StatusIndicator';
import QueryForm from './components/QueryForm';
import IngestForm from './components/IngestForm';

function App() {
  const { status, setStatus } = useBackendStore();

  useEffect(() => {
    checkBackend()
      .then(setStatus)
      .catch(() => setStatus('unreachable'));
  }, [setStatus]);

  return (
    <Container maxWidth="md">
      <Box sx={{ my: 4 }}>
        <Typography variant="h3" component="h1" gutterBottom>
          God&rsquo;s Eye + RAG
        </Typography>
        <Paper sx={{ p: 2, mb: 2 }}>
          <StatusIndicator status={status} />
          {status === 'unreachable' && (
            <Alert severity="warning">
              Backend not detected. Ensure Docker Compose is running.
            </Alert>
          )}
        </Paper>
        <IngestForm />
        <QueryForm />
      </Box>
    </Container>
  );
}

export default App;
