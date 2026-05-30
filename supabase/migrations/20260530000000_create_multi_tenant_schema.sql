-- Migration: Create multi-tenant schema for Scan d'Absences
-- Date: 2026-05-30
-- Description: Creates tables for multi-tenant B2B SaaS with schools, profiles,
--   classes, students, absence logs, and per-student absence records.
--   Includes RLS policies for school-level data isolation.

-- ============================================================
-- 1. schools
-- ============================================================
CREATE TABLE schools (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- 2. profiles (extends Supabase Auth users)
-- ============================================================
CREATE TABLE profiles (
  id        UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  school_id UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  role      TEXT NOT NULL CHECK (role IN ('admin', 'teacher')),
  full_name TEXT NOT NULL
);

CREATE INDEX idx_profiles_school_id ON profiles(school_id);

-- ============================================================
-- 3. classes
-- ============================================================
CREATE TABLE classes (
  id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  name      TEXT NOT NULL
);

CREATE INDEX idx_classes_school_id ON classes(school_id);

-- ============================================================
-- 4. students
-- ============================================================
CREATE TABLE students (
  id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  class_id  UUID NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
  name      TEXT NOT NULL
);

CREATE INDEX idx_students_class_id ON students(class_id);

-- ============================================================
-- 5. absences_log (replaces shared_preferences history)
-- ============================================================
CREATE TABLE absences_log (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id         UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  class_id          UUID NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
  teacher_id        UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  scan_date         TEXT NOT NULL DEFAULT '',
  scanned_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  raw_json_output   JSONB NOT NULL
);

CREATE INDEX idx_absences_log_school_id ON absences_log(school_id);
CREATE INDEX idx_absences_log_class_id ON absences_log(class_id);
CREATE INDEX idx_absences_log_teacher_id ON absences_log(teacher_id);
CREATE INDEX idx_absences_log_scanned_at ON absences_log(scanned_at DESC);
CREATE INDEX idx_absences_log_school_time ON absences_log(school_id, scanned_at DESC);

-- ============================================================
-- 6. student_absences (per-student line-item records)
-- ============================================================
CREATE TABLE student_absences (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  absence_log_id  UUID NOT NULL REFERENCES absences_log(id) ON DELETE CASCADE,
  student_name    TEXT NOT NULL,
  is_absent       BOOLEAN NOT NULL DEFAULT false,
  absence_count   INTEGER NOT NULL DEFAULT 0,
  hours_absent    NUMERIC(5,2) NOT NULL DEFAULT 0.00
);

CREATE INDEX idx_student_absences_log_id ON student_absences(absence_log_id);

-- ============================================================
-- Enable Row Level Security on all tables
-- ============================================================
ALTER TABLE schools ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE classes ENABLE ROW LEVEL SECURITY;
ALTER TABLE students ENABLE ROW LEVEL SECURITY;
ALTER TABLE absences_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE student_absences ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- profiles policies
-- ============================================================
CREATE POLICY "Users can view own profile"
  ON profiles FOR SELECT
  USING (id = auth.uid());

CREATE POLICY "Users can update own profile"
  ON profiles FOR UPDATE
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

CREATE POLICY "Admins can insert profiles in their school"
  ON profiles FOR INSERT
  WITH CHECK (
    school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
    AND (SELECT role FROM profiles WHERE id = auth.uid()) = 'admin'
  );

CREATE POLICY "Admins can update profiles in their school"
  ON profiles FOR UPDATE
  USING (
    school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
    AND (SELECT role FROM profiles WHERE id = auth.uid()) = 'admin'
  );

CREATE POLICY "Admins can delete profiles in their school"
  ON profiles FOR DELETE
  USING (
    school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
    AND (SELECT role FROM profiles WHERE id = auth.uid()) = 'admin'
  );

-- ============================================================
-- schools policies
-- ============================================================
CREATE POLICY "Users can view own school"
  ON schools FOR SELECT
  USING (
    id = (SELECT school_id FROM profiles WHERE id = auth.uid())
  );

CREATE POLICY "Admins can update own school"
  ON schools FOR UPDATE
  USING (
    id = (SELECT school_id FROM profiles WHERE id = auth.uid())
    AND (SELECT role FROM profiles WHERE id = auth.uid()) = 'admin'
  );

-- ============================================================
-- classes policies
-- ============================================================
CREATE POLICY "Users can view classes in their school"
  ON classes FOR SELECT
  USING (
    school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
  );

CREATE POLICY "Admins can insert classes in their school"
  ON classes FOR INSERT
  WITH CHECK (
    school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
    AND (SELECT role FROM profiles WHERE id = auth.uid()) = 'admin'
  );

CREATE POLICY "Admins can update classes in their school"
  ON classes FOR UPDATE
  USING (
    school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
    AND (SELECT role FROM profiles WHERE id = auth.uid()) = 'admin'
  );

CREATE POLICY "Admins can delete classes in their school"
  ON classes FOR DELETE
  USING (
    school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
    AND (SELECT role FROM profiles WHERE id = auth.uid()) = 'admin'
  );

-- ============================================================
-- students policies
-- ============================================================
CREATE POLICY "Users can view students in their school"
  ON students FOR SELECT
  USING (
    class_id IN (
      SELECT id FROM classes
      WHERE school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
    )
  );

CREATE POLICY "Admins can insert students in their school"
  ON students FOR INSERT
  WITH CHECK (
    class_id IN (
      SELECT id FROM classes
      WHERE school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
    )
    AND (SELECT role FROM profiles WHERE id = auth.uid()) = 'admin'
  );

CREATE POLICY "Admins can update students in their school"
  ON students FOR UPDATE
  USING (
    class_id IN (
      SELECT id FROM classes
      WHERE school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
    )
    AND (SELECT role FROM profiles WHERE id = auth.uid()) = 'admin'
  );

CREATE POLICY "Admins can delete students in their school"
  ON students FOR DELETE
  USING (
    class_id IN (
      SELECT id FROM classes
      WHERE school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
    )
    AND (SELECT role FROM profiles WHERE id = auth.uid()) = 'admin'
  );

-- ============================================================
-- absences_log policies
-- ============================================================
CREATE POLICY "Users can view absence logs in their school"
  ON absences_log FOR SELECT
  USING (
    school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
  );

CREATE POLICY "Users can insert absence logs in their school"
  ON absences_log FOR INSERT
  WITH CHECK (
    school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
    AND teacher_id = auth.uid()
  );

CREATE POLICY "Users can update own absence logs"
  ON absences_log FOR UPDATE
  USING (
    school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
    AND teacher_id = auth.uid()
  );

CREATE POLICY "Users can delete absence logs"
  ON absences_log FOR DELETE
  USING (
    school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
    AND (
      teacher_id = auth.uid()
      OR (SELECT role FROM profiles WHERE id = auth.uid()) = 'admin'
    )
  );

-- ============================================================
-- student_absences policies
-- ============================================================
CREATE POLICY "Users can view student absences in their school"
  ON student_absences FOR SELECT
  USING (
    absence_log_id IN (
      SELECT id FROM absences_log
      WHERE school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
    )
  );

CREATE POLICY "Users can insert student absences"
  ON student_absences FOR INSERT
  WITH CHECK (
    absence_log_id IN (
      SELECT id FROM absences_log
      WHERE school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
      AND teacher_id = auth.uid()
    )
  );

CREATE POLICY "Users can update student absences"
  ON student_absences FOR UPDATE
  USING (
    absence_log_id IN (
      SELECT id FROM absences_log
      WHERE school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
      AND teacher_id = auth.uid()
    )
  );

CREATE POLICY "Users can delete student absences"
  ON student_absences FOR DELETE
  USING (
    absence_log_id IN (
      SELECT id FROM absences_log
      WHERE school_id = (SELECT school_id FROM profiles WHERE id = auth.uid())
      AND (
        teacher_id = auth.uid()
        OR (SELECT role FROM profiles WHERE id = auth.uid()) = 'admin'
      )
    )
  );
