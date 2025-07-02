#!/usr/bin/env python3
from google.cloud import storage
from googleapiclient import discovery
from oauth2client.client import GoogleCredentials
import datetime
import os

# Configuration
PROJECT_ID = 'encoded-alpha-457108-e8'
INSTANCE_NAME = os.getenv('CLOUD_SQL_INSTANCE_NAME')
BUCKET_NAME = os.getenv('BUCKET_NAME')
BACKUP_DIR = os.getenv('BACKUP_DIR')
DATABASE_NAME = None

def handler(event, context):
    # Authenticate
    credentials = GoogleCredentials.get_application_default()
    service = discovery.build('sqladmin', 'v1beta4', credentials=credentials)
    
    # Create export request body
    timestamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    backup_file = f'{INSTANCE_NAME}-{timestamp}.sql.gz'
    gs_uri = f'gs://{BUCKET_NAME}/{BACKUP_DIR}/{backup_file}'
    
    request_body = {
        'exportContext': {
            'kind': 'sql#exportContext',
            'fileType': 'SQL',
            'uri': gs_uri,
            'databases': [DATABASE_NAME] if DATABASE_NAME else None
        }
    }
    
    # Execute export
    print(f'Starting backup of {INSTANCE_NAME} to {gs_uri}')
    request = service.instances().export(
        project=PROJECT_ID,
        instance=INSTANCE_NAME,
        body=request_body
    )
    response = request.execute()
    
    print(f'Backup started successfully. Operation ID: {response["name"]}')
    return response