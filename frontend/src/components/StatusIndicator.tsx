import React from 'react';
import { Chip } from '@mui/material';
import { BackendStatus } from '../stores/backendStore';

interface Props {
  status: BackendStatus;
}

const StatusIndicator: React.FC<Props> = ({ status }) => {
  const color = status === 'ok' ? 'success' : status === 'unreachable' ? 'error' : 'default';
  const label = status === 'ok' ? 'Backend Online' : status === 'unreachable' ? 'Backend Unreachable' : 'Checking...';
  return <Chip label={`Status: ${label}`} color={color} />;
};

export default StatusIndicator;
