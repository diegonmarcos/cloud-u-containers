-- Photos Project - PostgreSQL Schema
-- Version: 1.0.0
-- Created: 2025-12-06

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "earthdistance";
CREATE EXTENSION IF NOT EXISTS "cube";

-- Main photos table
CREATE TABLE IF NOT EXISTS photos (
    id BIGSERIAL PRIMARY KEY,

    -- File information
    filename VARCHAR(500) NOT NULL UNIQUE,
    s3_path TEXT NOT NULL UNIQUE,
    size_bytes BIGINT,
    file_hash VARCHAR(64),  -- SHA256 of file

    -- EXIF data
    taken_date TIMESTAMP,
    camera_model VARCHAR(255),
    camera_make VARCHAR(255),
    iso INT,
    shutter_speed VARCHAR(50),
    aperture VARCHAR(50),
    focal_length VARCHAR(50),
    exposure_bias VARCHAR(50),

    -- Location data
    latitude DECIMAL(10,8),
    longitude DECIMAL(11,8),
    location_name VARCHAR(500),
    altitude_meters INT,

    -- Deduplication
    perceptual_hash VARCHAR(64),  -- For visual duplicate detection

    -- Metadata
    width INT,
    height INT,
    orientation INT,  -- EXIF orientation (1-8)
    color_profile VARCHAR(255),

    -- Timestamps
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    indexed_at TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes for fast queries
CREATE INDEX idx_photos_taken_date ON photos(taken_date DESC NULLS LAST);
CREATE INDEX idx_photos_camera ON photos(camera_model);
CREATE INDEX idx_photos_iso ON photos(iso);
CREATE INDEX idx_photos_location_name ON photos(location_name);
CREATE INDEX idx_photos_filename ON photos(filename);
CREATE INDEX idx_photos_perceptual_hash ON photos(perceptual_hash);
CREATE INDEX idx_photos_created_at ON photos(created_at DESC);

-- Geospatial index for fast location queries
CREATE INDEX idx_photos_location_geo ON photos USING GIST(
    ll_to_earth(latitude, longitude)
) WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

-- AI results table (populated in Phase 3)
CREATE TABLE IF NOT EXISTS photo_ai_results (
    photo_id BIGINT PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,

    -- Face detection results
    faces JSONB,  -- [{face_id, x, y, width, height, confidence, person_name}, ...]

    -- Object detection results
    objects JSONB,  -- [{label, confidence, x, y, width, height}, ...]

    -- Automatic tags
    tags TEXT[],  -- ['vacation', 'beach', 'sunset', ...]
    tags_confidence DECIMAL(3,2)[],  -- Confidence for each tag

    -- Color analysis
    dominant_colors JSONB,  -- [{color: "#FF5733", percentage: 0.25}, ...]

    -- OCR results
    ocr_text TEXT,

    -- Perceptual analysis
    quality_score DECIMAL(3,2),  -- 0-1, based on blur, brightness, etc
    aesthetics_score DECIMAL(3,2),  -- 0-1, composition, rule of thirds, etc

    -- Processing metadata
    processing_status VARCHAR(50),  -- 'pending', 'processing', 'complete', 'error'
    processing_error VARCHAR(500),
    processing_timestamp TIMESTAMP,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Index for AI results queries
CREATE INDEX idx_ai_results_status ON photo_ai_results(processing_status);
CREATE INDEX idx_ai_results_timestamp ON photo_ai_results(processing_timestamp DESC);

-- Photo albums table (for manual and auto-generated albums)
CREATE TABLE IF NOT EXISTS photo_albums (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(500) NOT NULL,
    description TEXT,
    cover_photo_id BIGINT REFERENCES photos(id) ON DELETE SET NULL,
    is_auto_generated BOOLEAN DEFAULT FALSE,  -- TRUE for face/object albums
    generation_type VARCHAR(50),  -- 'face', 'object', 'tag', 'location', 'date', 'manual'
    generation_id VARCHAR(500),  -- face_id, object_label, tag, etc

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_albums_name ON photo_albums(name);
CREATE INDEX idx_albums_auto_generated ON photo_albums(is_auto_generated);
CREATE INDEX idx_albums_generation ON photo_albums(generation_type, generation_id);

-- Junction table: photos to albums
CREATE TABLE IF NOT EXISTS album_photos (
    album_id BIGINT NOT NULL REFERENCES photo_albums(id) ON DELETE CASCADE,
    photo_id BIGINT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
    sort_order INT,

    PRIMARY KEY (album_id, photo_id)
);

CREATE INDEX idx_album_photos_photo ON album_photos(photo_id);

-- Processing queue for AI tasks (Phase 3)
CREATE TABLE IF NOT EXISTS photo_processing_queue (
    id BIGSERIAL PRIMARY KEY,
    photo_id BIGINT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
    task_type VARCHAR(50),  -- 'face_detection', 'object_detection', 'tagging', 'quality_score'
    status VARCHAR(50) DEFAULT 'pending',  -- 'pending', 'processing', 'complete', 'failed'
    retry_count INT DEFAULT 0,
    max_retries INT DEFAULT 3,
    error_message TEXT,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    started_at TIMESTAMP,
    completed_at TIMESTAMP
);

CREATE INDEX idx_queue_status ON photo_processing_queue(status);
CREATE INDEX idx_queue_photo_id ON photo_processing_queue(photo_id);
CREATE INDEX idx_queue_task_type ON photo_processing_queue(task_type);

-- Statistics table for dashboard
CREATE TABLE IF NOT EXISTS photo_stats (
    id SERIAL PRIMARY KEY,
    total_photos BIGINT,
    total_size_gb DECIMAL(10,2),
    photos_with_location BIGINT,
    photos_with_faces BIGINT,
    earliest_date TIMESTAMP,
    latest_date TIMESTAMP,
    most_used_camera VARCHAR(255),
    most_used_location VARCHAR(500),

    calculated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Audit log for tracking changes
CREATE TABLE IF NOT EXISTS audit_log (
    id BIGSERIAL PRIMARY KEY,
    table_name VARCHAR(100),
    operation VARCHAR(10),  -- 'INSERT', 'UPDATE', 'DELETE'
    record_id BIGINT,
    changes JSONB,
    changed_by VARCHAR(255),

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_audit_log_created ON audit_log(created_at DESC);
CREATE INDEX idx_audit_log_table ON audit_log(table_name);

-- Create user role for application
CREATE ROLE photos_user WITH LOGIN PASSWORD 'SECURE_PASSWORD_HERE';
GRANT CONNECT ON DATABASE photos TO photos_user;
GRANT USAGE ON SCHEMA public TO photos_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO photos_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO photos_user;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO photos_user;

-- Create view for quick photo browsing
CREATE VIEW v_photos_with_counts AS
SELECT
    p.id,
    p.filename,
    p.s3_path,
    p.taken_date,
    p.camera_model,
    p.latitude,
    p.longitude,
    p.location_name,
    COUNT(DISTINCT a.album_id) as album_count,
    CASE WHEN ar.photo_id IS NOT NULL THEN TRUE ELSE FALSE END as has_ai_results,
    CASE WHEN ar.faces IS NOT NULL THEN jsonb_array_length(ar.faces) ELSE 0 END as face_count
FROM photos p
LEFT JOIN album_photos a ON p.id = a.photo_id
LEFT JOIN photo_ai_results ar ON p.id = ar.photo_id
GROUP BY p.id, p.filename, p.s3_path, p.taken_date, p.camera_model,
         p.latitude, p.longitude, p.location_name, ar.photo_id, ar.faces;

-- Create view for photo timeline
CREATE VIEW v_photo_timeline AS
SELECT
    DATE_TRUNC('month', taken_date)::DATE as month,
    COUNT(*) as count,
    MIN(taken_date) as earliest,
    MAX(taken_date) as latest
FROM photos
WHERE taken_date IS NOT NULL
GROUP BY DATE_TRUNC('month', taken_date)
ORDER BY month DESC;

-- Create view for location statistics
CREATE VIEW v_photos_by_location AS
SELECT
    location_name,
    COUNT(*) as count,
    AVG(latitude) as avg_latitude,
    AVG(longitude) as avg_longitude,
    MIN(taken_date) as earliest,
    MAX(taken_date) as latest
FROM photos
WHERE location_name IS NOT NULL
GROUP BY location_name
ORDER BY count DESC;

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Triggers for updated_at
CREATE TRIGGER update_photos_updated_at BEFORE UPDATE ON photos
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_ai_results_updated_at BEFORE UPDATE ON photo_ai_results
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_albums_updated_at BEFORE UPDATE ON photo_albums
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Grant permissions on views
GRANT SELECT ON v_photos_with_counts TO photos_user;
GRANT SELECT ON v_photo_timeline TO photos_user;
GRANT SELECT ON v_photos_by_location TO photos_user;

-- Summary
COMMENT ON TABLE photos IS 'Main photos table - stores metadata, EXIF, location for all photos';
COMMENT ON TABLE photo_ai_results IS 'AI-generated results - faces, objects, tags (populated by ml-Agentic)';
COMMENT ON TABLE photo_albums IS 'Photo albums - both manual and auto-generated from AI results';
COMMENT ON TABLE photo_processing_queue IS 'Queue for AI processing tasks';
