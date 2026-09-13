from unittest.mock import patch

from django.db import OperationalError
from django.test import SimpleTestCase


class HealthTests(SimpleTestCase):
    def test_liveness_does_not_require_database(self):
        response = self.client.get('/health/live/')
        self.assertEqual(response.status_code, 200)

    @patch('P1.health.connection')
    def test_readiness_checks_database(self, connection):
        response = self.client.get('/health/ready/')
        self.assertEqual(response.status_code, 200)
        connection.cursor.return_value.__enter__.return_value.execute.assert_called_once_with('SELECT 1')

    @patch('P1.health.connection')
    def test_database_failure_only_fails_readiness(self, connection):
        connection.cursor.side_effect = OperationalError('private connection details')
        response = self.client.get('/health/ready/')
        self.assertEqual(response.status_code, 503)
        self.assertNotContains(response, 'private connection details', status_code=503)
        self.assertEqual(self.client.get('/health/live/').status_code, 200)
