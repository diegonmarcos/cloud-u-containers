#!/usr/bin/env python3
"""
Photos Project - S3 Webhook Processor
Triggers on S3 photo upload, extracts EXIF + geocodes
"""

import os
import sys
import json
import logging
import tempfile
from datetime import datetime
from pathlib import Path

# Third-party imports
import boto3
import psycopg2
from psycopg2.extras import Json
import piexif
from PIL import Image
import imagehash
import geopy.geocoders
from geopy.exc import GeocoderTimedOut

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration
DB_HOST = os.getenv('DB_HOST', 'localhost')
DB_NAME = os.getenv('DB_NAME', 'photos')
DB_USER = os.getenv('DB_USER', 'photos_user')
DB_PASS = os.getenv('DB_PASS', 'SECURE_PASSWORD_HERE')

S3_ACCESS_KEY = os.getenv('S3_ACCESS_KEY')
S3_SECRET_KEY = os.getenv('S3_SECRET_KEY')
S3_REGION = os.getenv('S3_REGION', 'eu-marseille-1')
S3_BUCKET = os.getenv('S3_BUCKET', 'photos')


class PhotoProcessor:
    """Process photos: extract EXIF, geocode, store metadata"""

    def __init__(self):
        self.s3_client = boto3.client(
            's3',
            aws_access_key_id=S3_ACCESS_KEY,
            aws_secret_access_key=S3_SECRET_KEY,
            region_name=S3_REGION
        )
        self.geolocator = geopy.geocoders.Nominatim(user_agent="photos-app")
        self.db_conn = None

    def connect_db(self):
        """Connect to PostgreSQL"""
        try:
            self.db_conn = psycopg2.connect(
                host=DB_HOST,
                database=DB_NAME,
                user=DB_USER,
                password=DB_PASS
            )
            logger.info("Connected to PostgreSQL")
        except psycopg2.Error as e:
            logger.error(f"Database connection failed: {e}")
            raise

    def disconnect_db(self):
        """Close database connection"""
        if self.db_conn:
            self.db_conn.close()

    def download_from_s3(self, s3_key: str, bucket: str) -> str:
        """Download photo from S3 to temporary location"""
        try:
            temp_dir = tempfile.gettempdir()
            temp_path = os.path.join(temp_dir, os.path.basename(s3_key))

            logger.info(f"Downloading {s3_key} to {temp_path}")
            self.s3_client.download_file(bucket, s3_key, temp_path)

            return temp_path
        except Exception as e:
            logger.error(f"S3 download failed: {e}")
            raise

    def extract_exif(self, photo_path: str) -> dict:
        """Extract EXIF data from photo"""
        exif_data = {
            'taken_date': None,
            'camera_model': None,
            'camera_make': None,
            'iso': None,
            'shutter_speed': None,
            'aperture': None,
            'focal_length': None,
            'latitude': None,
            'longitude': None,
            'altitude_meters': None,
        }

        try:
            with open(photo_path, 'rb') as f:
                exif_dict = piexif.load(f)

            # Camera info (0th IFD)
            if '271' in exif_dict['0th']:  # Model
                exif_data['camera_model'] = piexif.util.get_orientation(exif_dict['0th'])
            if '271' in exif_dict['0th']:
                exif_data['camera_make'] = exif_dict['0th'].get(271)

            # DateTime (0th IFD)
            if '306' in exif_dict['0th']:
                dt_str = exif_dict['0th'][306].decode() if isinstance(exif_dict['0th'][306], bytes) else exif_dict['0th'][306]
                exif_data['taken_date'] = datetime.strptime(dt_str, '%Y:%m:%d %H:%M:%S')

            # Exif IFD
            if 'Exif' in exif_dict:
                # ISO
                if piexif.ExifIFD.ISOSpeedRatings in exif_dict['Exif']:
                    exif_data['iso'] = exif_dict['Exif'][piexif.ExifIFD.ISOSpeedRatings]

                # Shutter Speed
                if piexif.ExifIFD.ExposureTime in exif_dict['Exif']:
                    num, den = exif_dict['Exif'][piexif.ExifIFD.ExposureTime]
                    exif_data['shutter_speed'] = f"1/{int(den/num)}" if num > 0 else f"{num}/{den}"

                # Aperture (F-number)
                if piexif.ExifIFD.FNumber in exif_dict['Exif']:
                    num, den = exif_dict['Exif'][piexif.ExifIFD.FNumber]
                    exif_data['aperture'] = f"f/{num/den:.1f}"

                # Focal Length
                if piexif.ExifIFD.FocalLength in exif_dict['Exif']:
                    num, den = exif_dict['Exif'][piexif.ExifIFD.FocalLength]
                    exif_data['focal_length'] = f"{num/den:.1f}mm"

            # GPS IFD
            if 'GPS' in exif_dict:
                gps = exif_dict['GPS']

                # Latitude
                if piexif.GPSIFD.GPSLatitude in gps:
                    lat = self._parse_gps_coord(gps[piexif.GPSIFD.GPSLatitude])
                    lat_ref = gps.get(piexif.GPSIFD.GPSLatitudeRef, b'N').decode()
                    exif_data['latitude'] = lat if lat_ref == 'N' else -lat

                # Longitude
                if piexif.GPSIFD.GPSLongitude in gps:
                    lon = self._parse_gps_coord(gps[piexif.GPSIFD.GPSLongitude])
                    lon_ref = gps.get(piexif.GPSIFD.GPSLongitudeRef, b'E').decode()
                    exif_data['longitude'] = lon if lon_ref == 'E' else -lon

                # Altitude
                if piexif.GPSIFD.GPSAltitude in gps:
                    alt_num, alt_den = gps[piexif.GPSIFD.GPSAltitude]
                    exif_data['altitude_meters'] = int(alt_num / alt_den)

            logger.info(f"EXIF extracted: {exif_data}")
            return exif_data

        except Exception as e:
            logger.warning(f"EXIF extraction failed: {e}")
            return exif_data

    @staticmethod
    def _parse_gps_coord(gps_coord_tuple) -> float:
        """Parse GPS coordinate tuple to decimal degrees"""
        d, m, s = gps_coord_tuple
        d_num, d_den = d
        m_num, m_den = m
        s_num, s_den = s

        d_float = d_num / d_den
        m_float = m_num / m_den
        s_float = s_num / s_den

        return d_float + m_float / 60 + s_float / 3600

    def reverse_geocode(self, latitude: float, longitude: float) -> str:
        """Get location name from coordinates"""
        if not latitude or not longitude:
            return None

        try:
            location = self.geolocator.reverse(f"{latitude}, {longitude}", language='en')
            logger.info(f"Reverse geocoded: {location.address}")
            return location.address
        except GeocoderTimedOut:
            logger.warning(f"Geocoding timeout for {latitude}, {longitude}")
            return None
        except Exception as e:
            logger.warning(f"Geocoding failed: {e}")
            return None

    def compute_hashes(self, photo_path: str) -> dict:
        """Compute file and perceptual hashes"""
        hashes = {
            'file_hash': None,
            'perceptual_hash': None,
        }

        try:
            # Perceptual hash (for duplicate detection)
            with Image.open(photo_path) as img:
                hashes['perceptual_hash'] = str(imagehash.phash(img))

            # File hash (SHA256)
            import hashlib
            with open(photo_path, 'rb') as f:
                hashes['file_hash'] = hashlib.sha256(f.read()).hexdigest()

            logger.info(f"Hashes computed: {hashes}")
            return hashes

        except Exception as e:
            logger.warning(f"Hash computation failed: {e}")
            return hashes

    def get_image_dimensions(self, photo_path: str) -> dict:
        """Get image dimensions"""
        try:
            with Image.open(photo_path) as img:
                return {
                    'width': img.width,
                    'height': img.height,
                    'orientation': img._getexif().get(274, 1) if hasattr(img, '_getexif') else 1
                }
        except Exception as e:
            logger.warning(f"Image dimension extraction failed: {e}")
            return {'width': None, 'height': None, 'orientation': 1}

    def save_to_database(self, s3_key: str, s3_bucket: str, photo_path: str) -> int:
        """Save photo metadata to PostgreSQL"""
        try:
            # Extract all metadata
            exif = self.extract_exif(photo_path)
            hashes = self.compute_hashes(photo_path)
            dims = self.get_image_dimensions(photo_path)
            file_size = os.path.getsize(photo_path)

            # Geocode if we have location
            location_name = None
            if exif['latitude'] and exif['longitude']:
                location_name = self.reverse_geocode(exif['latitude'], exif['longitude'])

            # Insert into database
            cur = self.db_conn.cursor()
            cur.execute("""
                INSERT INTO photos (
                    filename, s3_path, size_bytes, file_hash,
                    taken_date, camera_model, camera_make, iso,
                    shutter_speed, aperture, focal_length,
                    latitude, longitude, location_name, altitude_meters,
                    perceptual_hash, width, height, orientation,
                    indexed_at
                ) VALUES (
                    %s, %s, %s, %s,
                    %s, %s, %s, %s,
                    %s, %s, %s,
                    %s, %s, %s, %s,
                    %s, %s, %s, %s,
                    CURRENT_TIMESTAMP
                )
                RETURNING id
            """, (
                os.path.basename(s3_key),
                f"s3://{s3_bucket}/{s3_key}",
                file_size,
                hashes['file_hash'],

                exif['taken_date'],
                exif['camera_model'],
                exif['camera_make'],
                exif['iso'],

                exif['shutter_speed'],
                exif['aperture'],
                exif['focal_length'],

                exif['latitude'],
                exif['longitude'],
                location_name,
                exif['altitude_meters'],

                hashes['perceptual_hash'],
                dims['width'],
                dims['height'],
                dims['orientation']
            ))

            photo_id = cur.fetchone()[0]
            self.db_conn.commit()

            logger.info(f"Saved to database with ID: {photo_id}")
            return photo_id

        except psycopg2.Error as e:
            self.db_conn.rollback()
            logger.error(f"Database insert failed: {e}")
            raise
        finally:
            cur.close()

    def process_photo(self, s3_key: str, s3_bucket: str) -> dict:
        """Main processing function"""
        temp_path = None
        try:
            logger.info(f"Processing photo: {s3_key}")

            # Download
            temp_path = self.download_from_s3(s3_key, s3_bucket)

            # Save to database
            photo_id = self.save_to_database(s3_key, s3_bucket, temp_path)

            result = {
                'status': 'success',
                'photo_id': photo_id,
                's3_key': s3_key,
                'message': f'Photo {s3_key} indexed successfully'
            }

            logger.info(f"Processing complete: {result}")
            return result

        except Exception as e:
            logger.error(f"Photo processing failed: {e}")
            return {
                'status': 'error',
                's3_key': s3_key,
                'message': str(e)
            }

        finally:
            # Cleanup
            if temp_path and os.path.exists(temp_path):
                os.remove(temp_path)
                logger.info(f"Cleaned up temp file: {temp_path}")

    def process_batch(self, s3_keys: list, s3_bucket: str) -> list:
        """Process multiple photos"""
        results = []
        for s3_key in s3_keys:
            result = self.process_photo(s3_key, s3_bucket)
            results.append(result)
        return results


# Flask webhook endpoint
def create_flask_app():
    """Create Flask app for webhook endpoint"""
    from flask import Flask, request, jsonify

    app = Flask(__name__)

    @app.post("/webhook/s3-photo-upload")
    def handle_s3_upload():
        """Handle S3 event notification"""
        try:
            event = request.json

            if not event or 'Records' not in event:
                return jsonify({'error': 'Invalid event format'}), 400

            processor = PhotoProcessor()
            processor.connect_db()

            results = []
            for record in event['Records']:
                s3_key = record['s3']['object']['key']
                s3_bucket = record['s3']['bucket']['name']

                result = processor.process_photo(s3_key, s3_bucket)
                results.append(result)

            processor.disconnect_db()

            # Check if all succeeded
            all_success = all(r['status'] == 'success' for r in results)
            status_code = 200 if all_success else 207

            return jsonify({
                'status': 'success' if all_success else 'partial',
                'results': results
            }), status_code

        except Exception as e:
            logger.error(f"Webhook error: {e}")
            return jsonify({
                'error': str(e)
            }), 500

    @app.get("/health")
    def health_check():
        """Health check endpoint"""
        try:
            processor = PhotoProcessor()
            processor.connect_db()
            processor.disconnect_db()
            return jsonify({'status': 'healthy'}), 200
        except Exception as e:
            return jsonify({'status': 'unhealthy', 'error': str(e)}), 503

    return app


if __name__ == '__main__':
    import sys

    if len(sys.argv) > 1 and sys.argv[1] == 'flask':
        # Run Flask server
        app = create_flask_app()
        app.run(
            host='0.0.0.0',
            port=int(os.getenv('WEBHOOK_PORT', 5001)),
            debug=False
        )
    else:
        # Run command-line processor for testing
        if len(sys.argv) < 3:
            print("Usage: python webhook.py <s3-key> <s3-bucket>")
            sys.exit(1)

        s3_key = sys.argv[1]
        s3_bucket = sys.argv[2]

        processor = PhotoProcessor()
        processor.connect_db()
        result = processor.process_photo(s3_key, s3_bucket)
        processor.disconnect_db()

        print(json.dumps(result, indent=2))
        sys.exit(0 if result['status'] == 'success' else 1)
