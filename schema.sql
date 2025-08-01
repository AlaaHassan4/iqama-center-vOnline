--
-- PostgreSQL database dump
--

-- Dumped from database version 17.5
-- Dumped by pg_dump version 17.5

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: enrollment_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enrollment_status AS ENUM (
    'pending_payment',
    'waiting_start',
    'active',
    'completed',
    'cancelled',
    'pending_approval'
);


--
-- Name: TYPE enrollment_status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TYPE public.enrollment_status IS 'Enrollment status: pending_payment (students/parents), pending_approval (workers in training), waiting_start (approved but course not started), active (course is running), completed (finished course)';


--
-- Name: notification_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.notification_type AS ENUM (
    'new_task',
    'payment_reminder',
    'meeting_reminder',
    'message',
    'announcement',
    'course_published',
    'course_launched',
    'course_enrollment',
    'course_approval_needed',
    'course_auto_launched',
    'course_message'
);


--
-- Name: payment_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.payment_status AS ENUM (
    'due',
    'paid',
    'late',
    'waived',
    'pending_review'
);


--
-- Name: submission_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.submission_status AS ENUM (
    'pending',
    'submitted',
    'graded',
    'late'
);


--
-- Name: task_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.task_type AS ENUM (
    'homework',
    'exam',
    'reading',
    'daily_wird',
    'review'
);


--
-- Name: user_role; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.user_role AS ENUM (
    'student',
    'parent',
    'teacher',
    'worker',
    'head',
    'finance',
    'admin'
);


--
-- Name: check_auto_launch_conditions(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_auto_launch_conditions(course_id_param integer) RETURNS boolean
    LANGUAGE plpgsql
    AS $$

DECLARE

    course_record RECORD;

    level_record RECORD;

    should_launch BOOLEAN := FALSE;

    days_before INTEGER;

    auto_settings JSONB;

    current_enrollments INTEGER;

    min_threshold INTEGER;

    optimal_threshold INTEGER;

    max_threshold INTEGER;

BEGIN

    SELECT * INTO course_record FROM courses WHERE id = course_id_param;

    

    IF NOT FOUND OR course_record.is_launched OR NOT course_record.is_published THEN

        RETURN FALSE;

    END IF;

    

    days_before := EXTRACT(DAY FROM (course_record.start_date - CURRENT_DATE));

    

    IF days_before < 0 THEN

        RETURN FALSE;

    END IF;

    

    auto_settings := course_record.auto_launch_settings;

    

    SELECT COUNT(*) INTO current_enrollments 

    FROM enrollments 

    WHERE course_id = course_id_param AND status = 'active';

    

    SELECT 

        SUM(min_count) as min_total,

        SUM(optimal_count) as optimal_total,

        SUM(max_count) as max_total

    INTO min_threshold, optimal_threshold, max_threshold

    FROM course_participant_levels 

    WHERE course_id = course_id_param;

    

    

    IF (auto_settings->>'auto_launch_on_max_capacity')::boolean = true 

       AND current_enrollments >= max_threshold 

       AND days_before >= 1 THEN

        should_launch := TRUE;

    END IF;

    

    IF (auto_settings->>'auto_launch_on_optimal_capacity')::boolean = true 

       AND current_enrollments >= optimal_threshold 

       AND days_before = 1 THEN

        should_launch := TRUE;

    END IF;

    

    IF (auto_settings->>'auto_launch_on_min_capacity')::boolean = true 

       AND current_enrollments >= min_threshold 

       AND days_before = 1 THEN

        should_launch := TRUE;

    END IF;

    

    RETURN should_launch;

END;

$$;


--
-- Name: create_course_tasks_from_templates(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_course_tasks_from_templates(course_id_param integer) RETURNS void
    LANGUAGE plpgsql
    AS $$

DECLARE

    template_record RECORD;

    schedule_record RECORD;

    enrollment_record RECORD;

    task_due_date TIMESTAMP WITH TIME ZONE;

BEGIN

    FOR schedule_record IN 

        SELECT * FROM course_schedule 

        WHERE course_id = course_id_param 

        ORDER BY day_number

    LOOP

        FOR template_record IN 

            SELECT * FROM course_task_templates 

            WHERE course_id = course_id_param

        LOOP

            FOR enrollment_record IN 

                SELECT DISTINCT e.user_id, u.role 

                FROM enrollments e 

                JOIN users u ON e.user_id = u.id 

                JOIN course_participant_levels cpl ON cpl.course_id = e.course_id 

                WHERE e.course_id = course_id_param 

                AND e.status = 'active' 

                AND u.role = ANY(cpl.target_roles) 

                AND cpl.level_number = template_record.level_number

            LOOP

                SELECT start_date + (schedule_record.day_number - 1) * INTERVAL '1 day' 

                INTO task_due_date 

                FROM courses 

                WHERE id = course_id_param;

                

                INSERT INTO tasks (

                    schedule_id, task_type, title, description, due_date,

                    assigned_to, level_number, course_id, max_score, 

                    instructions, created_by, is_active

                ) VALUES (

                    schedule_record.id,

                    template_record.task_type,

                    template_record.title,

                    template_record.description,

                    task_due_date + INTERVAL '23:59:59',

                    enrollment_record.user_id,

                    template_record.level_number,

                    course_id_param,

                    template_record.max_score,

                    template_record.default_instructions,

                    (SELECT created_by FROM courses WHERE id = course_id_param),

                    false

                );

            END LOOP;

        END LOOP;

    END LOOP;

END;

$$;


--
-- Name: generate_course_content(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_course_content(template_id integer, course_id integer) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$

DECLARE

    template_data RECORD;

    generated_content JSONB := '{}';

BEGIN

    SELECT * INTO template_data FROM course_auto_fill_templates WHERE id = template_id;

    

    IF NOT FOUND THEN

        RETURN '{"error": "Template not found"}';

    END IF;

    

    IF template_data.meeting_link_template IS NOT NULL THEN

        generated_content := jsonb_set(

            generated_content, 

            '{meeting_links}', 

            to_jsonb(ARRAY(

                SELECT replace(template_data.meeting_link_template, '{n}', i::text)

                FROM generate_series(

                    template_data.url_numbering_start, 

                    template_data.url_numbering_end

                ) AS i

            ))

        );

    END IF;

    

    IF template_data.content_url_template IS NOT NULL THEN

        generated_content := jsonb_set(

            generated_content, 

            '{content_urls}', 

            to_jsonb(ARRAY(

                SELECT replace(template_data.content_url_template, '{n}', i::text)

                FROM generate_series(

                    template_data.url_numbering_start, 

                    template_data.url_numbering_end

                ) AS i

            ))

        );

    END IF;

    

    generated_content := jsonb_set(

        generated_content, 

        '{assignments}', 

        template_data.default_assignments

    );

    

    RETURN generated_content;

END;

$$;


--
-- Name: get_course_level_statistics(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_course_level_statistics(course_id_param integer) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$

DECLARE

    stats JSONB := '{}';

    level_stats RECORD;

BEGIN

    FOR level_stats IN 

        SELECT 

            cpl.level_number,

            cpl.level_name,

            cpl.min_count,

            cpl.max_count,

            cpl.optimal_count,

            COUNT(e.id) as current_count,

            cpl.target_roles

        FROM course_participant_levels cpl

        LEFT JOIN enrollments e ON e.course_id = cpl.course_id 

            AND e.status = 'active'

            AND EXISTS (

                SELECT 1 FROM users u 

                WHERE u.id = e.user_id 

                AND u.role = ANY(cpl.target_roles)

            )

        WHERE cpl.course_id = course_id_param

        GROUP BY cpl.level_number, cpl.level_name, cpl.min_count, cpl.max_count, cpl.optimal_count, cpl.target_roles

        ORDER BY cpl.level_number

    LOOP

        stats := jsonb_set(

            stats, 

            ('{level_' || level_stats.level_number || '}')::text[], 

            jsonb_build_object(

                'level_number', level_stats.level_number,

                'level_name', level_stats.level_name,

                'current_count', level_stats.current_count,

                'min_count', level_stats.min_count,

                'max_count', level_stats.max_count,

                'optimal_count', level_stats.optimal_count,

                'target_roles', to_jsonb(level_stats.target_roles),

                'is_min_met', level_stats.current_count >= level_stats.min_count,

                'is_optimal_met', level_stats.current_count >= level_stats.optimal_count,

                'is_max_reached', level_stats.current_count >= level_stats.max_count

            )

        );

    END LOOP;

    

    RETURN stats;

END;

$$;


--
-- Name: get_course_statistics(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_course_statistics(course_id_param integer) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$

DECLARE

    stats JSONB := '{}';

    total_enrolled INTEGER;

    level_stats JSONB := '{}';

BEGIN

    SELECT COUNT(*) INTO total_enrolled 

    FROM enrollments 

    WHERE course_id = course_id_param AND status = 'active';

    

    stats := jsonb_set(stats, '{total_enrolled}', to_jsonb(total_enrolled));

    

    FOR level_stats IN 

        SELECT jsonb_build_object(

            'level_number', cpl.level_number,

            'level_name', cpl.level_name,

            'current_count', COUNT(e.id),

            'min_count', cpl.min_count,

            'max_count', cpl.max_count,

            'optimal_count', cpl.optimal_count

        ) as level_data

        FROM course_participant_levels cpl

        LEFT JOIN enrollments e ON e.course_id = cpl.course_id 

            AND e.status = 'active'

            AND EXISTS (

                SELECT 1 FROM users u 

                WHERE u.id = e.user_id 

                AND u.role = ANY(cpl.target_roles)

            )

        WHERE cpl.course_id = course_id_param

        GROUP BY cpl.level_number, cpl.level_name, cpl.min_count, cpl.max_count, cpl.optimal_count

    LOOP

        stats := jsonb_set(stats, ('{levels,' || (level_stats->>'level_number') || '}')::text[], level_stats);

    END LOOP;

    

    RETURN stats;

END;

$$;


--
-- Name: update_enrollment_states_on_course_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_enrollment_states_on_course_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$

BEGIN

    IF NEW.status = 'active' AND OLD.status != 'active' THEN

        UPDATE enrollments 

        SET status = 'active' 

        WHERE course_id = NEW.id AND status = 'waiting_start';

        

        INSERT INTO notifications (user_id, type, message, related_id, created_at)

        SELECT 

            e.user_id,

            'course_launched',

            '╪ذ╪»╪ث╪ز ╪»┘ê╪▒╪ر ' || NEW.name || '! ┘è┘à┘â┘┘â ╪د┘╪ت┘ ╪د┘┘ê╪╡┘ê┘ ╪ح┘┘ë ┘à╪ص╪ز┘ê┘ë ╪د┘╪»┘ê╪▒╪ر ┘ê╪د┘┘à╪┤╪د╪▒┘â╪ر ┘┘è ╪د┘╪ث┘╪┤╪╖╪ر.',

            NEW.id,

            CURRENT_TIMESTAMP

        FROM enrollments e

        WHERE e.course_id = NEW.id AND e.status = 'active';

    END IF;

    

    IF NEW.status = 'completed' AND OLD.status != 'completed' THEN

        UPDATE enrollments 

        SET status = 'completed' 

        WHERE course_id = NEW.id AND status = 'active';

        

        INSERT INTO notifications (user_id, type, message, related_id, created_at)

        SELECT 

            e.user_id,

            'course_completed',

            '╪ز┘ç╪د┘┘è┘╪د! ┘┘é╪» ╪ث┘â┘à┘╪ز ╪»┘ê╪▒╪ر ' || NEW.name || ' ╪ذ┘╪ش╪د╪ص.',

            NEW.id,

            CURRENT_TIMESTAMP

        FROM enrollments e

        WHERE e.course_id = NEW.id AND e.status = 'completed';

    END IF;

    

    RETURN NEW;

END;

$$;


--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$

BEGIN

    NEW.updated_at = CURRENT_TIMESTAMP;

    RETURN NEW;

END;

$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: courses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.courses (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    created_by integer NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    details jsonb DEFAULT '{}'::jsonb,
    status character varying(20) DEFAULT 'draft'::character varying,
    approved_by integer,
    approved_at timestamp with time zone,
    template_id integer,
    current_enrollment integer DEFAULT 0,
    min_enrollment integer DEFAULT 7,
    max_enrollment integer DEFAULT 15,
    duration_days integer DEFAULT 7,
    start_date date,
    days_per_week integer DEFAULT 5,
    hours_per_day numeric(3,1) DEFAULT 2.0,
    content_outline text,
    auto_launch_settings jsonb DEFAULT '{}'::jsonb,
    participant_config jsonb DEFAULT '{}'::jsonb,
    is_published boolean DEFAULT false,
    is_launched boolean DEFAULT false,
    launched_at timestamp with time zone,
    launch_date timestamp with time zone,
    teacher_id integer,
    course_fee numeric(10,2) DEFAULT 0.00,
    max_participants integer DEFAULT 50,
    end_date date,
    is_public boolean DEFAULT true,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT check_days_per_week_valid CHECK (((days_per_week >= 1) AND (days_per_week <= 7))),
    CONSTRAINT check_duration_days_positive CHECK ((duration_days > 0)),
    CONSTRAINT check_hours_per_day_valid CHECK (((hours_per_day > (0)::numeric) AND (hours_per_day <= (24)::numeric))),
    CONSTRAINT check_max_enrollment_valid CHECK ((max_enrollment >= min_enrollment)),
    CONSTRAINT check_min_enrollment_positive CHECK ((min_enrollment > 0))
);


--
-- Name: COLUMN courses.details; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.courses.details IS 'Stores structured course data: cost, currency, teachers, max_seats, target_roles, prerequisites, etc. (JSON format)';


--
-- Name: COLUMN courses.duration_days; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.courses.duration_days IS '┘à╪»╪ر ╪د┘╪»┘ê╪▒╪ر ╪ذ╪د┘╪ث┘è╪د┘à';


--
-- Name: COLUMN courses.start_date; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.courses.start_date IS '╪ز╪د╪▒┘è╪« ╪ذ╪»╪ة ╪د┘╪»┘ê╪▒╪ر';


--
-- Name: COLUMN courses.days_per_week; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.courses.days_per_week IS '╪╣╪»╪» ╪ث┘è╪د┘à ╪د┘╪»┘ê╪▒╪ر ┘┘è ╪د┘╪ث╪│╪ذ┘ê╪╣';


--
-- Name: COLUMN courses.hours_per_day; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.courses.hours_per_day IS '╪╣╪»╪» ╪│╪د╪╣╪د╪ز ╪د┘┘è┘ê┘à ╪د┘╪»╪▒╪د╪│┘è';


--
-- Name: COLUMN courses.content_outline; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.courses.content_outline IS '╪ش╪»┘ê┘ ┘à╪ص╪ز┘ê┘è╪د╪ز ╪د┘╪»┘ê╪▒╪ر';


--
-- Name: COLUMN courses.auto_launch_settings; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.courses.auto_launch_settings IS 'Automatic launch settings: auto_launch_on_max_capacity, auto_launch_on_optimal_capacity, auto_launch_on_min_capacity (JSON format)';


--
-- Name: COLUMN courses.participant_config; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.courses.participant_config IS 'Three-level participant system configuration: level_1 (supervisors), level_2 (managers/teachers), level_3 (students/recipients) with min/max/optimal counts and target roles (JSON format)';


--
-- Name: COLUMN courses.is_published; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.courses.is_published IS '┘ç┘ ╪د┘╪»┘ê╪▒╪ر ┘à┘╪┤┘ê╪▒╪ر ┘┘┘à╪┤╪د╪▒┘â┘è┘';


--
-- Name: COLUMN courses.is_launched; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.courses.is_launched IS '┘ç┘ ╪ز┘à ╪ذ╪»╪ة ╪د┘╪╖┘╪د┘é ╪د┘╪»┘ê╪▒╪ر';


--
-- Name: COLUMN courses.launched_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.courses.launched_at IS '╪ز╪د╪▒┘è╪« ┘ê┘ê┘é╪ز ╪د┘╪╖┘╪د┘é ╪د┘╪»┘ê╪▒╪ر';


--
-- Name: COLUMN courses.teacher_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.courses.teacher_id IS 'Reference to the teacher/instructor of the course';


--
-- Name: COLUMN courses.course_fee; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.courses.course_fee IS 'Course fee amount';


--
-- Name: COLUMN courses.max_participants; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.courses.max_participants IS 'Maximum number of participants allowed';


--
-- Name: COLUMN courses.end_date; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.courses.end_date IS 'Course end date';


--
-- Name: enrollments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enrollments (
    id integer NOT NULL,
    user_id integer NOT NULL,
    course_id integer NOT NULL,
    status public.enrollment_status DEFAULT 'pending_payment'::public.enrollment_status NOT NULL,
    enrolled_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    grade jsonb,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    id integer NOT NULL,
    enrollment_id integer NOT NULL,
    amount numeric(10,2) NOT NULL,
    currency character varying(10) NOT NULL,
    due_date date NOT NULL,
    status public.payment_status DEFAULT 'due'::public.payment_status NOT NULL,
    payment_proof_url character varying(255),
    paid_at timestamp with time zone,
    confirmed_by integer,
    notes text
);


--
-- Name: TABLE payments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.payments IS 'Course payment records and tracking';


--
-- Name: user_edit_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_edit_requests (
    id integer NOT NULL,
    user_id integer NOT NULL,
    field_name character varying(50) NOT NULL,
    old_value text,
    new_value text NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying,
    requested_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    reviewed_by integer,
    reviewed_at timestamp with time zone
);


--
-- Name: TABLE user_edit_requests; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.user_edit_requests IS 'User profile edit requests for admin approval';


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id integer NOT NULL,
    full_name character varying(255) NOT NULL,
    email character varying(255) NOT NULL,
    phone character varying(50) NOT NULL,
    password_hash character varying(255) NOT NULL,
    role public.user_role NOT NULL,
    reports_to integer,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    details jsonb DEFAULT '{}'::jsonb,
    avatar_url character varying(255),
    email_verified boolean DEFAULT false,
    phone_verified boolean DEFAULT false,
    account_status character varying(20) DEFAULT 'pending_verification'::character varying,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: COLUMN users.phone; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.phone IS 'Phone number - no longer unique to allow multiple users with same phone (family members, etc.)';


--
-- Name: COLUMN users.reports_to; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.reports_to IS 'ID of the manager or head of department this user reports to.';


--
-- Name: COLUMN users.details; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.users.details IS 'Stores flexible data like gender, birth_date, nationality, languages, notes from parents, etc.';


--
-- Name: admin_dashboard_stats; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.admin_dashboard_stats AS
 SELECT ( SELECT count(*) AS count
           FROM public.users
          WHERE (((users.account_status)::text = 'active'::text) OR (users.account_status IS NULL))) AS total_users,
    ( SELECT count(*) AS count
           FROM public.users
          WHERE ((users.role = 'student'::public.user_role) AND (((users.account_status)::text = 'active'::text) OR (users.account_status IS NULL)))) AS total_students,
    ( SELECT count(*) AS count
           FROM public.users
          WHERE ((users.role = 'teacher'::public.user_role) AND (((users.account_status)::text = 'active'::text) OR (users.account_status IS NULL)))) AS total_teachers,
    ( SELECT count(*) AS count
           FROM public.users
          WHERE ((users.role = 'admin'::public.user_role) AND (((users.account_status)::text = 'active'::text) OR (users.account_status IS NULL)))) AS total_admins,
    ( SELECT count(*) AS count
           FROM public.users
          WHERE ((users.role = 'parent'::public.user_role) AND (((users.account_status)::text = 'active'::text) OR (users.account_status IS NULL)))) AS total_parents,
    ( SELECT count(*) AS count
           FROM public.users
          WHERE ((users.role = 'worker'::public.user_role) AND (((users.account_status)::text = 'active'::text) OR (users.account_status IS NULL)))) AS total_workers,
    ( SELECT count(*) AS count
           FROM public.courses) AS total_courses,
    ( SELECT count(*) AS count
           FROM public.courses
          WHERE ((courses.status)::text = 'active'::text)) AS active_courses,
    ( SELECT count(*) AS count
           FROM public.courses
          WHERE ((courses.status)::text = 'published'::text)) AS published_courses,
    ( SELECT count(*) AS count
           FROM public.courses
          WHERE ((courses.status)::text = 'draft'::text)) AS draft_courses,
    ( SELECT count(*) AS count
           FROM public.enrollments
          WHERE (enrollments.status = 'active'::public.enrollment_status)) AS active_enrollments,
    ( SELECT count(*) AS count
           FROM public.enrollments
          WHERE (enrollments.status = 'completed'::public.enrollment_status)) AS completed_enrollments,
    ( SELECT count(*) AS count
           FROM public.enrollments
          WHERE (enrollments.status = 'pending_approval'::public.enrollment_status)) AS pending_enrollments,
    ( SELECT count(*) AS count
           FROM public.enrollments
          WHERE (enrollments.status = 'pending_payment'::public.enrollment_status)) AS payment_pending_enrollments,
    ( SELECT count(DISTINCT e.user_id) AS count
           FROM (public.enrollments e
             JOIN public.users u ON ((e.user_id = u.id)))
          WHERE ((e.status = 'active'::public.enrollment_status) AND (u.role = 'student'::public.user_role) AND (((u.account_status)::text = 'active'::text) OR (u.account_status IS NULL)))) AS unique_active_students,
    COALESCE(( SELECT count(*) AS count
           FROM public.payments
          WHERE (payments.status = ANY (ARRAY['due'::public.payment_status, 'pending_review'::public.payment_status, 'late'::public.payment_status]))), (0)::bigint) AS pending_payments,
    COALESCE(( SELECT count(*) AS count
           FROM public.payments
          WHERE (payments.status = 'paid'::public.payment_status)), (0)::bigint) AS completed_payments,
    COALESCE(( SELECT count(*) AS count
           FROM public.user_edit_requests
          WHERE ((user_edit_requests.status)::text = 'pending'::text)), (0)::bigint) AS pending_requests,
    CURRENT_TIMESTAMP AS last_updated;


--
-- Name: announcements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.announcements (
    id integer NOT NULL,
    title character varying(255) NOT NULL,
    content text NOT NULL,
    priority character varying(20) DEFAULT 'normal'::character varying,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    expires_at timestamp without time zone,
    created_by integer,
    target_roles text[] DEFAULT ARRAY['student'::text, 'teacher'::text, 'admin'::text, 'parent'::text, 'worker'::text, 'finance'::text, 'head'::text],
    CONSTRAINT announcements_priority_check CHECK (((priority)::text = ANY ((ARRAY['low'::character varying, 'normal'::character varying, 'high'::character varying, 'urgent'::character varying])::text[])))
);


--
-- Name: TABLE announcements; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.announcements IS 'General announcements table';


--
-- Name: announcements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.announcements_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: announcements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.announcements_id_seq OWNED BY public.announcements.id;


--
-- Name: attendance; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attendance (
    id integer NOT NULL,
    user_id integer NOT NULL,
    course_id integer NOT NULL,
    schedule_id integer,
    date date DEFAULT CURRENT_DATE NOT NULL,
    status character varying(20) DEFAULT 'present'::character varying,
    notes text,
    recorded_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    recorded_by integer,
    CONSTRAINT attendance_status_check CHECK (((status)::text = ANY ((ARRAY['present'::character varying, 'absent'::character varying, 'late'::character varying, 'excused'::character varying])::text[])))
);


--
-- Name: TABLE attendance; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.attendance IS 'Student attendance records';


--
-- Name: attendance_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.attendance_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: attendance_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.attendance_id_seq OWNED BY public.attendance.id;


--
-- Name: certificates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.certificates (
    id integer NOT NULL,
    enrollment_id integer NOT NULL,
    issue_date date DEFAULT CURRENT_DATE NOT NULL,
    certificate_code character varying(100) NOT NULL,
    grade numeric(5,2)
);


--
-- Name: certificates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.certificates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: certificates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.certificates_id_seq OWNED BY public.certificates.id;


--
-- Name: course_auto_fill_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.course_auto_fill_templates (
    id integer NOT NULL,
    course_id integer NOT NULL,
    meeting_link_template character varying(500),
    content_url_template character varying(500),
    url_numbering_start integer DEFAULT 1,
    url_numbering_end integer DEFAULT 10,
    default_assignments jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    is_active boolean DEFAULT true,
    name character varying(200),
    description text
);


--
-- Name: TABLE course_auto_fill_templates; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.course_auto_fill_templates IS '╪ش╪»┘ê┘ ┘é┘ê╪د┘╪ذ ╪د┘┘à┘╪ة ╪د┘╪ز┘┘é╪د╪خ┘è ┘┘╪▒┘ê╪د╪ذ╪╖ ┘ê╪د┘┘à╪ص╪ز┘ê┘ë';


--
-- Name: course_auto_fill_templates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.course_auto_fill_templates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: course_auto_fill_templates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.course_auto_fill_templates_id_seq OWNED BY public.course_auto_fill_templates.id;


--
-- Name: course_auto_launch_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.course_auto_launch_log (
    id integer NOT NULL,
    course_id integer NOT NULL,
    launch_reason character varying(100) NOT NULL,
    enrollment_counts jsonb NOT NULL,
    launched_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    launched_by character varying(50) DEFAULT 'system'::character varying,
    success boolean DEFAULT true
);


--
-- Name: TABLE course_auto_launch_log; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.course_auto_launch_log IS '╪ش╪»┘ê┘ ╪│╪ش┘ ╪د┘╪د┘╪╖┘╪د┘é ╪د┘╪ز┘┘é╪د╪خ┘è ┘┘╪»┘ê╪▒╪د╪ز';


--
-- Name: course_auto_launch_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.course_auto_launch_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: course_auto_launch_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.course_auto_launch_log_id_seq OWNED BY public.course_auto_launch_log.id;


--
-- Name: course_daily_progress; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.course_daily_progress (
    id integer NOT NULL,
    course_id integer,
    day_number integer NOT NULL,
    date date NOT NULL,
    tasks_released boolean DEFAULT false,
    content_released boolean DEFAULT false,
    meeting_completed boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: course_daily_progress_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.course_daily_progress_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: course_daily_progress_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.course_daily_progress_id_seq OWNED BY public.course_daily_progress.id;


--
-- Name: course_exam_questions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.course_exam_questions (
    id integer NOT NULL,
    exam_id integer NOT NULL,
    question_text text NOT NULL,
    question_type character varying(50) NOT NULL,
    options jsonb DEFAULT '[]'::jsonb,
    correct_answer text,
    points numeric(5,2) DEFAULT 1.00,
    question_order integer DEFAULT 1,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: TABLE course_exam_questions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.course_exam_questions IS '╪ش╪»┘ê┘ ╪ث╪│╪خ┘╪ر ╪د┘╪د┘à╪ز╪ص╪د┘╪د╪ز (╪د╪«╪ز┘è╪د╪▒╪د╪ز ┘à╪ز╪╣╪»╪»╪ر ┘ê╪╡╪ص/╪«╪╖╪ث)';


--
-- Name: course_exam_questions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.course_exam_questions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: course_exam_questions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.course_exam_questions_id_seq OWNED BY public.course_exam_questions.id;


--
-- Name: course_exam_submissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.course_exam_submissions (
    id integer NOT NULL,
    exam_id integer NOT NULL,
    user_id integer NOT NULL,
    answers jsonb NOT NULL,
    score numeric(5,2),
    submitted_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    graded_at timestamp with time zone,
    graded_by integer
);


--
-- Name: TABLE course_exam_submissions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.course_exam_submissions IS '╪ش╪»┘ê┘ ╪ح╪ش╪د╪ذ╪د╪ز ╪د┘╪╖┘╪د╪ذ ╪╣┘┘ë ╪د┘╪د┘à╪ز╪ص╪د┘╪د╪ز';


--
-- Name: course_exam_submissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.course_exam_submissions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: course_exam_submissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.course_exam_submissions_id_seq OWNED BY public.course_exam_submissions.id;


--
-- Name: course_exams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.course_exams (
    id integer NOT NULL,
    course_id integer NOT NULL,
    schedule_day_id integer,
    exam_title character varying(200) NOT NULL,
    exam_description text,
    time_limit_minutes integer DEFAULT 60,
    passing_score numeric(5,2) DEFAULT 70.00,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: TABLE course_exams; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.course_exams IS '╪ش╪»┘ê┘ ╪د┘à╪ز╪ص╪د┘╪د╪ز ╪د┘╪»┘ê╪▒╪ر ╪د┘┘è┘ê┘à┘è╪ر';


--
-- Name: course_exams_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.course_exams_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: course_exams_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.course_exams_id_seq OWNED BY public.course_exams.id;


--
-- Name: course_management_view; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.course_management_view AS
SELECT
    NULL::integer AS id,
    NULL::character varying(255) AS name,
    NULL::text AS description,
    NULL::integer AS created_by,
    NULL::timestamp with time zone AS created_at,
    NULL::jsonb AS details,
    NULL::character varying(20) AS status,
    NULL::integer AS approved_by,
    NULL::timestamp with time zone AS approved_at,
    NULL::integer AS template_id,
    NULL::integer AS current_enrollment,
    NULL::integer AS min_enrollment,
    NULL::integer AS max_enrollment,
    NULL::integer AS duration_days,
    NULL::date AS start_date,
    NULL::integer AS days_per_week,
    NULL::numeric(3,1) AS hours_per_day,
    NULL::text AS content_outline,
    NULL::jsonb AS auto_launch_settings,
    NULL::jsonb AS participant_config,
    NULL::boolean AS is_published,
    NULL::boolean AS is_launched,
    NULL::timestamp with time zone AS launched_at,
    NULL::timestamp with time zone AS launch_date,
    NULL::character varying(255) AS created_by_name,
    NULL::bigint AS current_enrollment_count,
    NULL::bigint AS pending_payment_count,
    NULL::bigint AS pending_approval_count,
    NULL::bigint AS waiting_start_count,
    NULL::bigint AS active_enrollment_count,
    NULL::bigint AS completed_enrollment_count,
    NULL::text AS status_description;


--
-- Name: course_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.course_messages (
    id integer NOT NULL,
    course_id integer NOT NULL,
    user_id integer NOT NULL,
    message text NOT NULL,
    message_type character varying(50) DEFAULT 'general'::character varying,
    parent_message_id integer,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: TABLE course_messages; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.course_messages IS 'Stores course-specific messages and announcements';


--
-- Name: course_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.course_messages_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: course_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.course_messages_id_seq OWNED BY public.course_messages.id;


--
-- Name: course_messages_view; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.course_messages_view AS
 SELECT cm.id,
    cm.course_id,
    cm.user_id,
    cm.message,
    cm.message_type,
    cm.parent_message_id,
    cm.created_at,
    cm.updated_at,
    u.full_name AS author_name,
    u.role AS author_role,
    c.name AS course_name,
    ( SELECT count(*) AS count
           FROM public.course_messages
          WHERE (course_messages.parent_message_id = cm.id)) AS reply_count
   FROM ((public.course_messages cm
     JOIN public.users u ON ((cm.user_id = u.id)))
     JOIN public.courses c ON ((cm.course_id = c.id)));


--
-- Name: course_participant_levels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.course_participant_levels (
    id integer NOT NULL,
    course_id integer NOT NULL,
    level_number integer NOT NULL,
    level_name character varying(100) NOT NULL,
    target_roles text[] NOT NULL,
    min_count integer DEFAULT 1,
    max_count integer DEFAULT 10,
    optimal_count integer DEFAULT 5,
    requirements jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: TABLE course_participant_levels; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.course_participant_levels IS 'Stores the 3-level participant system for courses (Level 1: Supervisor, Level 2: Manager, Level 3: Recipient)';


--
-- Name: course_participant_levels_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.course_participant_levels_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: course_participant_levels_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.course_participant_levels_id_seq OWNED BY public.course_participant_levels.id;


--
-- Name: course_ratings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.course_ratings (
    id integer NOT NULL,
    course_id integer NOT NULL,
    user_id integer NOT NULL,
    rating integer,
    comment text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT course_ratings_rating_check CHECK (((rating >= 1) AND (rating <= 5)))
);


--
-- Name: TABLE course_ratings; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.course_ratings IS 'Stores course ratings and feedback from participants';


--
-- Name: course_ratings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.course_ratings_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: course_ratings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.course_ratings_id_seq OWNED BY public.course_ratings.id;


--
-- Name: course_schedule; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.course_schedule (
    id integer NOT NULL,
    course_id integer NOT NULL,
    day_number integer NOT NULL,
    title character varying(255) NOT NULL,
    content_url character varying(255),
    meeting_link character varying(255),
    scheduled_date date,
    exam_content jsonb DEFAULT '{}'::jsonb,
    assignments jsonb DEFAULT '{}'::jsonb,
    level_specific_content jsonb DEFAULT '{}'::jsonb,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    meeting_start_time time without time zone,
    meeting_end_time time without time zone,
    tasks_released boolean DEFAULT false
);


--
-- Name: TABLE course_schedule; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.course_schedule IS 'Course scheduling and session management';


--
-- Name: COLUMN course_schedule.content_url; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.course_schedule.content_url IS '╪▒╪د╪ذ╪╖ ╪د┘┘à╪ص╪ز┘ê┘ë (PDF/Video)';


--
-- Name: COLUMN course_schedule.meeting_link; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.course_schedule.meeting_link IS '╪▒╪د╪ذ╪╖ ╪د┘┘┘é╪د╪ة (Zoom/Meet)';


--
-- Name: COLUMN course_schedule.scheduled_date; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.course_schedule.scheduled_date IS '╪ز╪د╪▒┘è╪« ╪د┘┘è┘ê┘à ╪د┘╪»╪▒╪د╪│┘è';


--
-- Name: COLUMN course_schedule.exam_content; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.course_schedule.exam_content IS '┘à╪ص╪ز┘ê┘ë ╪د┘à╪ز╪ص╪د┘ ╪د┘┘è┘ê┘à (JSON)';


--
-- Name: COLUMN course_schedule.assignments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.course_schedule.assignments IS '╪د┘╪ز┘â╪د┘┘è┘ ╪ص╪│╪ذ ╪د┘┘à╪│╪ز┘ê┘ë (JSON)';


--
-- Name: COLUMN course_schedule.level_specific_content; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.course_schedule.level_specific_content IS '┘à╪ص╪ز┘ê┘ë ╪«╪د╪╡ ╪ذ┘â┘ ╪»╪▒╪ش╪ر (JSON)';


--
-- Name: course_schedule_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.course_schedule_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: course_schedule_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.course_schedule_id_seq OWNED BY public.course_schedule.id;


--
-- Name: exams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.exams (
    id integer NOT NULL,
    course_id integer NOT NULL,
    day_number integer NOT NULL,
    title character varying(200) NOT NULL,
    description text,
    questions jsonb DEFAULT '[]'::jsonb NOT NULL,
    time_limit integer DEFAULT 60,
    max_attempts integer DEFAULT 1,
    passing_score numeric(5,2) DEFAULT 60.00,
    is_active boolean DEFAULT true,
    created_by integer NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: TABLE exams; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.exams IS '╪ش╪»┘ê┘ ╪د┘╪د┘à╪ز╪ص╪د┘╪د╪ز ╪د┘┘è┘ê┘à┘è╪ر ┘┘╪»┘ê╪▒╪د╪ز';


--
-- Name: course_statistics_view; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.course_statistics_view AS
 SELECT c.id,
    c.name,
    c.status,
    c.is_published,
    c.is_launched,
    c.start_date,
    c.duration_days,
    count(DISTINCT e.id) AS total_enrollments,
    count(DISTINCT
        CASE
            WHEN (e.status = 'active'::public.enrollment_status) THEN e.id
            ELSE NULL::integer
        END) AS active_enrollments,
    count(DISTINCT
        CASE
            WHEN (e.status = 'pending_payment'::public.enrollment_status) THEN e.id
            ELSE NULL::integer
        END) AS pending_payment,
    count(DISTINCT
        CASE
            WHEN (e.status = 'pending_approval'::public.enrollment_status) THEN e.id
            ELSE NULL::integer
        END) AS pending_approval,
    count(DISTINCT cm.id) AS total_messages,
    count(DISTINCT ex.id) AS total_exams,
    u.full_name AS created_by_name
   FROM ((((public.courses c
     LEFT JOIN public.enrollments e ON ((c.id = e.course_id)))
     LEFT JOIN public.course_messages cm ON ((c.id = cm.course_id)))
     LEFT JOIN public.exams ex ON ((c.id = ex.course_id)))
     LEFT JOIN public.users u ON ((c.created_by = u.id)))
  GROUP BY c.id, c.name, c.status, c.is_published, c.is_launched, c.start_date, c.duration_days, u.full_name;


--
-- Name: VIEW course_statistics_view; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.course_statistics_view IS 'Course statistics view updated to use exams table instead of course_exams table for accurate exam counts';


--
-- Name: course_task_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.course_task_templates (
    id integer NOT NULL,
    course_id integer,
    level_number integer NOT NULL,
    task_type public.task_type NOT NULL,
    title character varying(255) NOT NULL,
    description text,
    default_instructions text,
    max_score numeric(5,2) DEFAULT 100,
    is_daily boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: course_task_templates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.course_task_templates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: course_task_templates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.course_task_templates_id_seq OWNED BY public.course_task_templates.id;


--
-- Name: course_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.course_templates (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    duration_days integer NOT NULL,
    target_roles jsonb DEFAULT '[]'::jsonb,
    min_capacity integer DEFAULT 7,
    max_capacity integer DEFAULT 15,
    optimal_capacity integer DEFAULT 12,
    pricing jsonb DEFAULT '{}'::jsonb,
    daily_content_template jsonb DEFAULT '[]'::jsonb,
    created_by integer NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    is_active boolean DEFAULT true,
    participant_config jsonb DEFAULT '{}'::jsonb,
    auto_fill_template jsonb DEFAULT '{}'::jsonb,
    launch_settings jsonb DEFAULT '{}'::jsonb
);


--
-- Name: TABLE course_templates; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.course_templates IS 'Stores reusable course templates for quick course creation';


--
-- Name: course_templates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.course_templates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: course_templates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.course_templates_id_seq OWNED BY public.course_templates.id;


--
-- Name: courses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.courses_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: courses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.courses_id_seq OWNED BY public.courses.id;


--
-- Name: daily_commitments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_commitments (
    id integer NOT NULL,
    user_id integer NOT NULL,
    commitment_date date DEFAULT CURRENT_DATE NOT NULL,
    commitments jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: TABLE daily_commitments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.daily_commitments IS 'Daily spiritual and educational commitments for users';


--
-- Name: daily_commitments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.daily_commitments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: daily_commitments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.daily_commitments_id_seq OWNED BY public.daily_commitments.id;


--
-- Name: enrollments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.enrollments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: enrollments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.enrollments_id_seq OWNED BY public.enrollments.id;


--
-- Name: exam_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.exam_attempts (
    id integer NOT NULL,
    exam_id integer,
    user_id integer,
    answers jsonb NOT NULL,
    score numeric(5,2) NOT NULL,
    total_points numeric(5,2) NOT NULL,
    earned_points numeric(5,2) NOT NULL,
    passed boolean NOT NULL,
    completed_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: exam_attempts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.exam_attempts_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: exam_attempts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.exam_attempts_id_seq OWNED BY public.exam_attempts.id;


--
-- Name: exam_submissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.exam_submissions (
    id integer NOT NULL,
    exam_id integer NOT NULL,
    user_id integer NOT NULL,
    answers jsonb DEFAULT '{}'::jsonb NOT NULL,
    score numeric(5,2),
    total_questions integer,
    correct_answers integer,
    started_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    submitted_at timestamp with time zone,
    time_taken integer,
    attempt_number integer DEFAULT 1
);


--
-- Name: TABLE exam_submissions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.exam_submissions IS '╪ش╪»┘ê┘ ╪ح╪ش╪د╪ذ╪د╪ز ╪د┘╪╖┘╪د╪ذ ╪╣┘┘ë ╪د┘╪د┘à╪ز╪ص╪د┘╪د╪ز';


--
-- Name: exam_submissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.exam_submissions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: exam_submissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.exam_submissions_id_seq OWNED BY public.exam_submissions.id;


--
-- Name: exams_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.exams_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: exams_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.exams_id_seq OWNED BY public.exams.id;


--
-- Name: messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messages (
    id integer NOT NULL,
    sender_id integer NOT NULL,
    recipient_id integer NOT NULL,
    content text NOT NULL,
    sent_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    read_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    subject character varying(255),
    is_read boolean DEFAULT false
);


--
-- Name: messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messages_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messages_id_seq OWNED BY public.messages.id;


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id integer NOT NULL,
    user_id integer NOT NULL,
    type public.notification_type NOT NULL,
    message text NOT NULL,
    link character varying(255),
    is_read boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    related_type character varying(50),
    title character varying(255),
    content text,
    related_id integer
);


--
-- Name: notifications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notifications_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notifications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notifications_id_seq OWNED BY public.notifications.id;


--
-- Name: parent_child_relationships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parent_child_relationships (
    parent_id integer NOT NULL,
    child_id integer NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: TABLE parent_child_relationships; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.parent_child_relationships IS 'Relationships between parent and child users';


--
-- Name: payments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.payments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: payments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.payments_id_seq OWNED BY public.payments.id;


--
-- Name: performance_evaluations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.performance_evaluations (
    id integer NOT NULL,
    user_id integer,
    course_id integer,
    level_number integer NOT NULL,
    evaluation_date date DEFAULT CURRENT_DATE,
    task_completion_score numeric(5,2) DEFAULT 0,
    quality_score numeric(5,2) DEFAULT 0,
    timeliness_score numeric(5,2) DEFAULT 0,
    overall_score numeric(5,2) DEFAULT 0,
    performance_data jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: performance_evaluations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.performance_evaluations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: performance_evaluations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.performance_evaluations_id_seq OWNED BY public.performance_evaluations.id;


--
-- Name: submissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.submissions (
    id integer NOT NULL,
    task_id integer NOT NULL,
    user_id integer NOT NULL,
    status public.submission_status DEFAULT 'pending'::public.submission_status NOT NULL,
    submitted_at timestamp with time zone,
    content text,
    grade numeric(5,2),
    feedback text
);


--
-- Name: TABLE submissions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.submissions IS 'Student task submissions and grades';


--
-- Name: submissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.submissions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: submissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.submissions_id_seq OWNED BY public.submissions.id;


--
-- Name: system_announcements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_announcements (
    id integer NOT NULL,
    title character varying(255) NOT NULL,
    content text NOT NULL,
    priority character varying(20) DEFAULT 'normal'::character varying,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    expires_at timestamp without time zone,
    created_by integer,
    target_roles text[] DEFAULT ARRAY['student'::text, 'teacher'::text, 'admin'::text, 'parent'::text, 'worker'::text, 'finance'::text, 'head'::text],
    CONSTRAINT system_announcements_priority_check CHECK (((priority)::text = ANY ((ARRAY['low'::character varying, 'normal'::character varying, 'high'::character varying, 'urgent'::character varying])::text[])))
);


--
-- Name: TABLE system_announcements; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.system_announcements IS 'System-wide announcements and notifications';


--
-- Name: COLUMN system_announcements.priority; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.system_announcements.priority IS 'Announcement priority level';


--
-- Name: COLUMN system_announcements.target_roles; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.system_announcements.target_roles IS 'Array of user roles that should see this announcement';


--
-- Name: system_announcements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.system_announcements_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: system_announcements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.system_announcements_id_seq OWNED BY public.system_announcements.id;


--
-- Name: tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tasks (
    id integer NOT NULL,
    schedule_id integer NOT NULL,
    task_type public.task_type NOT NULL,
    title character varying(255) NOT NULL,
    description text,
    due_date timestamp with time zone,
    assigned_to integer,
    level_number integer,
    is_active boolean DEFAULT false,
    released_at timestamp with time zone,
    created_by integer,
    course_id integer,
    max_score numeric(5,2) DEFAULT 100,
    instructions text
);


--
-- Name: TABLE tasks; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.tasks IS 'Course tasks and assignments';


--
-- Name: tasks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tasks_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tasks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tasks_id_seq OWNED BY public.tasks.id;


--
-- Name: user_edit_requests_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_edit_requests_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_edit_requests_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_edit_requests_id_seq OWNED BY public.user_edit_requests.id;


--
-- Name: user_relationships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_relationships (
    id integer NOT NULL,
    parent_id integer,
    child_id integer,
    relationship_type character varying(50) DEFAULT 'parent_child'::character varying,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: user_relationships_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_relationships_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_relationships_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_relationships_id_seq OWNED BY public.user_relationships.id;


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: verification_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.verification_tokens (
    id integer NOT NULL,
    user_id integer,
    token character varying(255) NOT NULL,
    type character varying(20) NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT verification_tokens_type_check CHECK (((type)::text = ANY ((ARRAY['email'::character varying, 'phone'::character varying])::text[])))
);


--
-- Name: verification_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.verification_tokens_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: verification_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.verification_tokens_id_seq OWNED BY public.verification_tokens.id;


--
-- Name: worker_attendance; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.worker_attendance (
    id integer NOT NULL,
    worker_id integer NOT NULL,
    date date NOT NULL,
    check_in_time timestamp without time zone,
    check_out_time timestamp without time zone,
    break_start_time timestamp without time zone,
    break_end_time timestamp without time zone,
    total_hours numeric(5,2),
    overtime_hours numeric(5,2) DEFAULT 0,
    status character varying(30) DEFAULT 'present'::character varying,
    location character varying(255),
    ip_address inet,
    device_info text,
    notes text,
    approved_by integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: TABLE worker_attendance; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.worker_attendance IS 'Tracks worker attendance, check-in/out times, and attendance status';


--
-- Name: worker_attendance_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.worker_attendance_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: worker_attendance_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.worker_attendance_id_seq OWNED BY public.worker_attendance.id;


--
-- Name: worker_schedule; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.worker_schedule (
    id integer NOT NULL,
    worker_id integer NOT NULL,
    task_id integer,
    title character varying(255) NOT NULL,
    description text,
    scheduled_date date NOT NULL,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    location character varying(255),
    schedule_type character varying(50) DEFAULT 'work'::character varying,
    status character varying(30) DEFAULT 'scheduled'::character varying,
    recurring_pattern character varying(50),
    recurring_end_date date,
    notes text,
    created_by integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: TABLE worker_schedule; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.worker_schedule IS 'Manages worker schedules including meetings, work hours, and appointments';


--
-- Name: worker_tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.worker_tasks (
    id integer NOT NULL,
    title character varying(255) NOT NULL,
    description text,
    assigned_to integer NOT NULL,
    assigned_by integer NOT NULL,
    task_type character varying(50) DEFAULT 'general'::character varying,
    priority character varying(20) DEFAULT 'medium'::character varying,
    status character varying(30) DEFAULT 'pending'::character varying,
    due_date timestamp without time zone,
    start_date timestamp without time zone,
    completion_date timestamp without time zone,
    estimated_hours numeric(5,2),
    actual_hours numeric(5,2),
    department character varying(100),
    location character varying(255),
    notes text,
    attachments jsonb,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: TABLE worker_tasks; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.worker_tasks IS 'Stores all tasks assigned to workers with priority, status, and tracking information';


--
-- Name: worker_current_schedule; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.worker_current_schedule AS
 SELECT ws.id,
    ws.worker_id,
    ws.task_id,
    ws.title,
    ws.description,
    ws.scheduled_date,
    ws.start_time,
    ws.end_time,
    ws.location,
    ws.schedule_type,
    ws.status,
    ws.recurring_pattern,
    ws.recurring_end_date,
    ws.notes,
    ws.created_by,
    ws.created_at,
    ws.updated_at,
    u.full_name AS worker_name,
    wt.title AS task_title,
    wt.priority AS task_priority
   FROM ((public.worker_schedule ws
     JOIN public.users u ON ((ws.worker_id = u.id)))
     LEFT JOIN public.worker_tasks wt ON ((ws.task_id = wt.id)))
  WHERE (ws.scheduled_date >= CURRENT_DATE)
  ORDER BY ws.scheduled_date, ws.start_time;


--
-- Name: worker_performance; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.worker_performance (
    id integer NOT NULL,
    worker_id integer NOT NULL,
    evaluator_id integer NOT NULL,
    evaluation_period_start date NOT NULL,
    evaluation_period_end date NOT NULL,
    overall_rating numeric(3,2),
    punctuality_rating numeric(3,2),
    quality_rating numeric(3,2),
    communication_rating numeric(3,2),
    teamwork_rating numeric(3,2),
    initiative_rating numeric(3,2),
    strengths text,
    areas_for_improvement text,
    goals_next_period text,
    evaluator_comments text,
    worker_comments text,
    status character varying(30) DEFAULT 'draft'::character varying,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT worker_performance_communication_rating_check CHECK (((communication_rating >= (1)::numeric) AND (communication_rating <= (5)::numeric))),
    CONSTRAINT worker_performance_initiative_rating_check CHECK (((initiative_rating >= (1)::numeric) AND (initiative_rating <= (5)::numeric))),
    CONSTRAINT worker_performance_overall_rating_check CHECK (((overall_rating >= (1)::numeric) AND (overall_rating <= (5)::numeric))),
    CONSTRAINT worker_performance_punctuality_rating_check CHECK (((punctuality_rating >= (1)::numeric) AND (punctuality_rating <= (5)::numeric))),
    CONSTRAINT worker_performance_quality_rating_check CHECK (((quality_rating >= (1)::numeric) AND (quality_rating <= (5)::numeric))),
    CONSTRAINT worker_performance_teamwork_rating_check CHECK (((teamwork_rating >= (1)::numeric) AND (teamwork_rating <= (5)::numeric)))
);


--
-- Name: TABLE worker_performance; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.worker_performance IS 'Stores performance evaluations and ratings for workers';


--
-- Name: worker_timesheet; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.worker_timesheet (
    id integer NOT NULL,
    worker_id integer NOT NULL,
    task_id integer,
    date date NOT NULL,
    start_time time without time zone,
    end_time time without time zone,
    break_duration integer DEFAULT 0,
    hours_worked numeric(5,2) NOT NULL,
    overtime_hours numeric(5,2) DEFAULT 0,
    work_description text,
    location character varying(255),
    status character varying(30) DEFAULT 'pending'::character varying,
    approved_by integer,
    approved_at timestamp without time zone,
    week_start date,
    month_year character varying(7),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: TABLE worker_timesheet; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.worker_timesheet IS 'Tracks actual hours worked by workers for payroll and performance analysis';


--
-- Name: worker_dashboard_summary; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.worker_dashboard_summary AS
 SELECT w.id AS worker_id,
    w.full_name,
    w.email,
    count(
        CASE
            WHEN ((wt.status)::text = 'pending'::text) THEN 1
            ELSE NULL::integer
        END) AS pending_tasks,
    count(
        CASE
            WHEN ((wt.status)::text = 'completed'::text) THEN 1
            ELSE NULL::integer
        END) AS completed_tasks,
    COALESCE(sum(
        CASE
            WHEN (ts.date >= (CURRENT_DATE - '7 days'::interval)) THEN ts.hours_worked
            ELSE (0)::numeric
        END), (0)::numeric) AS hours_this_week,
    round(avg(wp.overall_rating), 1) AS avg_performance_rating
   FROM (((public.users w
     LEFT JOIN public.worker_tasks wt ON ((w.id = wt.assigned_to)))
     LEFT JOIN public.worker_timesheet ts ON ((w.id = ts.worker_id)))
     LEFT JOIN public.worker_performance wp ON ((w.id = wp.worker_id)))
  WHERE (w.role = 'worker'::public.user_role)
  GROUP BY w.id, w.full_name, w.email;


--
-- Name: worker_department_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.worker_department_assignments (
    id integer NOT NULL,
    worker_id integer NOT NULL,
    department_id integer NOT NULL,
    "position" character varying(100),
    start_date date NOT NULL,
    end_date date,
    is_primary boolean DEFAULT true,
    hourly_rate numeric(8,2),
    monthly_salary numeric(10,2),
    status character varying(30) DEFAULT 'active'::character varying,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: TABLE worker_department_assignments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.worker_department_assignments IS 'Links workers to departments with position and salary information';


--
-- Name: worker_department_assignments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.worker_department_assignments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: worker_department_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.worker_department_assignments_id_seq OWNED BY public.worker_department_assignments.id;


--
-- Name: worker_departments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.worker_departments (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    head_id integer,
    budget numeric(12,2),
    location character varying(255),
    contact_email character varying(255),
    contact_phone character varying(50),
    status character varying(30) DEFAULT 'active'::character varying,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: TABLE worker_departments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.worker_departments IS 'Defines organizational departments where workers are assigned';


--
-- Name: worker_departments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.worker_departments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: worker_departments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.worker_departments_id_seq OWNED BY public.worker_departments.id;


--
-- Name: worker_notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.worker_notifications (
    id integer NOT NULL,
    worker_id integer NOT NULL,
    notification_type character varying(50) NOT NULL,
    title character varying(255) NOT NULL,
    message text NOT NULL,
    priority character varying(20) DEFAULT 'normal'::character varying,
    read_status boolean DEFAULT false,
    action_required boolean DEFAULT false,
    action_url character varying(500),
    related_task_id integer,
    related_schedule_id integer,
    expires_at timestamp without time zone,
    created_by integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    read_at timestamp without time zone
);


--
-- Name: TABLE worker_notifications; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.worker_notifications IS 'Manages notifications specific to worker activities and tasks';


--
-- Name: worker_notifications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.worker_notifications_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: worker_notifications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.worker_notifications_id_seq OWNED BY public.worker_notifications.id;


--
-- Name: worker_performance_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.worker_performance_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: worker_performance_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.worker_performance_id_seq OWNED BY public.worker_performance.id;


--
-- Name: worker_performance_summary; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.worker_performance_summary AS
 SELECT wp.worker_id,
    u.full_name AS worker_name,
    count(*) AS total_evaluations,
    round(avg(wp.overall_rating), 2) AS avg_overall_rating,
    round(avg(wp.punctuality_rating), 2) AS avg_punctuality,
    round(avg(wp.quality_rating), 2) AS avg_quality,
    round(avg(wp.communication_rating), 2) AS avg_communication,
    round(avg(wp.teamwork_rating), 2) AS avg_teamwork,
    round(avg(wp.initiative_rating), 2) AS avg_initiative,
    max(wp.evaluation_period_end) AS last_evaluation_date
   FROM (public.worker_performance wp
     JOIN public.users u ON ((wp.worker_id = u.id)))
  WHERE ((wp.status)::text = 'finalized'::text)
  GROUP BY wp.worker_id, u.full_name;


--
-- Name: worker_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.worker_reports (
    id integer NOT NULL,
    worker_id integer NOT NULL,
    report_type character varying(50) NOT NULL,
    title character varying(255) NOT NULL,
    content text NOT NULL,
    report_date date NOT NULL,
    period_start date,
    period_end date,
    status character varying(30) DEFAULT 'draft'::character varying,
    submitted_to integer,
    submitted_at timestamp without time zone,
    reviewed_by integer,
    reviewed_at timestamp without time zone,
    reviewer_comments text,
    attachments jsonb,
    tags character varying(255),
    priority character varying(20) DEFAULT 'normal'::character varying,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: TABLE worker_reports; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.worker_reports IS 'Stores various reports submitted by workers (daily, weekly, project reports)';


--
-- Name: worker_reports_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.worker_reports_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: worker_reports_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.worker_reports_id_seq OWNED BY public.worker_reports.id;


--
-- Name: worker_schedule_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.worker_schedule_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: worker_schedule_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.worker_schedule_id_seq OWNED BY public.worker_schedule.id;


--
-- Name: worker_skills; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.worker_skills (
    id integer NOT NULL,
    worker_id integer NOT NULL,
    skill_name character varying(100) NOT NULL,
    skill_category character varying(50),
    proficiency_level character varying(30),
    years_experience integer,
    certified boolean DEFAULT false,
    certification_name character varying(255),
    certification_date date,
    certification_expiry date,
    notes text,
    verified_by integer,
    verified_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: TABLE worker_skills; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.worker_skills IS 'Tracks worker skills, certifications, and competencies';


--
-- Name: worker_skills_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.worker_skills_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: worker_skills_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.worker_skills_id_seq OWNED BY public.worker_skills.id;


--
-- Name: worker_tasks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.worker_tasks_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: worker_tasks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.worker_tasks_id_seq OWNED BY public.worker_tasks.id;


--
-- Name: worker_timesheet_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.worker_timesheet_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: worker_timesheet_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.worker_timesheet_id_seq OWNED BY public.worker_timesheet.id;


--
-- Name: announcements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcements ALTER COLUMN id SET DEFAULT nextval('public.announcements_id_seq'::regclass);


--
-- Name: attendance id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance ALTER COLUMN id SET DEFAULT nextval('public.attendance_id_seq'::regclass);


--
-- Name: certificates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.certificates ALTER COLUMN id SET DEFAULT nextval('public.certificates_id_seq'::regclass);


--
-- Name: course_auto_fill_templates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_auto_fill_templates ALTER COLUMN id SET DEFAULT nextval('public.course_auto_fill_templates_id_seq'::regclass);


--
-- Name: course_auto_launch_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_auto_launch_log ALTER COLUMN id SET DEFAULT nextval('public.course_auto_launch_log_id_seq'::regclass);


--
-- Name: course_daily_progress id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_daily_progress ALTER COLUMN id SET DEFAULT nextval('public.course_daily_progress_id_seq'::regclass);


--
-- Name: course_exam_questions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_exam_questions ALTER COLUMN id SET DEFAULT nextval('public.course_exam_questions_id_seq'::regclass);


--
-- Name: course_exam_submissions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_exam_submissions ALTER COLUMN id SET DEFAULT nextval('public.course_exam_submissions_id_seq'::regclass);


--
-- Name: course_exams id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_exams ALTER COLUMN id SET DEFAULT nextval('public.course_exams_id_seq'::regclass);


--
-- Name: course_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_messages ALTER COLUMN id SET DEFAULT nextval('public.course_messages_id_seq'::regclass);


--
-- Name: course_participant_levels id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_participant_levels ALTER COLUMN id SET DEFAULT nextval('public.course_participant_levels_id_seq'::regclass);


--
-- Name: course_ratings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_ratings ALTER COLUMN id SET DEFAULT nextval('public.course_ratings_id_seq'::regclass);


--
-- Name: course_schedule id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_schedule ALTER COLUMN id SET DEFAULT nextval('public.course_schedule_id_seq'::regclass);


--
-- Name: course_task_templates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_task_templates ALTER COLUMN id SET DEFAULT nextval('public.course_task_templates_id_seq'::regclass);


--
-- Name: course_templates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_templates ALTER COLUMN id SET DEFAULT nextval('public.course_templates_id_seq'::regclass);


--
-- Name: courses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.courses ALTER COLUMN id SET DEFAULT nextval('public.courses_id_seq'::regclass);


--
-- Name: daily_commitments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_commitments ALTER COLUMN id SET DEFAULT nextval('public.daily_commitments_id_seq'::regclass);


--
-- Name: enrollments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollments ALTER COLUMN id SET DEFAULT nextval('public.enrollments_id_seq'::regclass);


--
-- Name: exam_attempts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exam_attempts ALTER COLUMN id SET DEFAULT nextval('public.exam_attempts_id_seq'::regclass);


--
-- Name: exam_submissions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exam_submissions ALTER COLUMN id SET DEFAULT nextval('public.exam_submissions_id_seq'::regclass);


--
-- Name: exams id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exams ALTER COLUMN id SET DEFAULT nextval('public.exams_id_seq'::regclass);


--
-- Name: messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages ALTER COLUMN id SET DEFAULT nextval('public.messages_id_seq'::regclass);


--
-- Name: notifications id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications ALTER COLUMN id SET DEFAULT nextval('public.notifications_id_seq'::regclass);


--
-- Name: payments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments ALTER COLUMN id SET DEFAULT nextval('public.payments_id_seq'::regclass);


--
-- Name: performance_evaluations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.performance_evaluations ALTER COLUMN id SET DEFAULT nextval('public.performance_evaluations_id_seq'::regclass);


--
-- Name: submissions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.submissions ALTER COLUMN id SET DEFAULT nextval('public.submissions_id_seq'::regclass);


--
-- Name: system_announcements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_announcements ALTER COLUMN id SET DEFAULT nextval('public.system_announcements_id_seq'::regclass);


--
-- Name: tasks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks ALTER COLUMN id SET DEFAULT nextval('public.tasks_id_seq'::regclass);


--
-- Name: user_edit_requests id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_edit_requests ALTER COLUMN id SET DEFAULT nextval('public.user_edit_requests_id_seq'::regclass);


--
-- Name: user_relationships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_relationships ALTER COLUMN id SET DEFAULT nextval('public.user_relationships_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: verification_tokens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verification_tokens ALTER COLUMN id SET DEFAULT nextval('public.verification_tokens_id_seq'::regclass);


--
-- Name: worker_attendance id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_attendance ALTER COLUMN id SET DEFAULT nextval('public.worker_attendance_id_seq'::regclass);


--
-- Name: worker_department_assignments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_department_assignments ALTER COLUMN id SET DEFAULT nextval('public.worker_department_assignments_id_seq'::regclass);


--
-- Name: worker_departments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_departments ALTER COLUMN id SET DEFAULT nextval('public.worker_departments_id_seq'::regclass);


--
-- Name: worker_notifications id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_notifications ALTER COLUMN id SET DEFAULT nextval('public.worker_notifications_id_seq'::regclass);


--
-- Name: worker_performance id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_performance ALTER COLUMN id SET DEFAULT nextval('public.worker_performance_id_seq'::regclass);


--
-- Name: worker_reports id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_reports ALTER COLUMN id SET DEFAULT nextval('public.worker_reports_id_seq'::regclass);


--
-- Name: worker_schedule id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_schedule ALTER COLUMN id SET DEFAULT nextval('public.worker_schedule_id_seq'::regclass);


--
-- Name: worker_skills id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_skills ALTER COLUMN id SET DEFAULT nextval('public.worker_skills_id_seq'::regclass);


--
-- Name: worker_tasks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_tasks ALTER COLUMN id SET DEFAULT nextval('public.worker_tasks_id_seq'::regclass);


--
-- Name: worker_timesheet id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_timesheet ALTER COLUMN id SET DEFAULT nextval('public.worker_timesheet_id_seq'::regclass);


--
-- Name: announcements announcements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcements
    ADD CONSTRAINT announcements_pkey PRIMARY KEY (id);


--
-- Name: attendance attendance_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_pkey PRIMARY KEY (id);


--
-- Name: attendance attendance_user_id_course_id_date_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_user_id_course_id_date_key UNIQUE (user_id, course_id, date);


--
-- Name: certificates certificates_certificate_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_certificate_code_key UNIQUE (certificate_code);


--
-- Name: certificates certificates_enrollment_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_enrollment_id_key UNIQUE (enrollment_id);


--
-- Name: certificates certificates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_pkey PRIMARY KEY (id);


--
-- Name: course_auto_fill_templates course_auto_fill_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_auto_fill_templates
    ADD CONSTRAINT course_auto_fill_templates_pkey PRIMARY KEY (id);


--
-- Name: course_auto_launch_log course_auto_launch_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_auto_launch_log
    ADD CONSTRAINT course_auto_launch_log_pkey PRIMARY KEY (id);


--
-- Name: course_daily_progress course_daily_progress_course_id_day_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_daily_progress
    ADD CONSTRAINT course_daily_progress_course_id_day_number_key UNIQUE (course_id, day_number);


--
-- Name: course_daily_progress course_daily_progress_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_daily_progress
    ADD CONSTRAINT course_daily_progress_pkey PRIMARY KEY (id);


--
-- Name: course_exam_questions course_exam_questions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_exam_questions
    ADD CONSTRAINT course_exam_questions_pkey PRIMARY KEY (id);


--
-- Name: course_exam_submissions course_exam_submissions_exam_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_exam_submissions
    ADD CONSTRAINT course_exam_submissions_exam_id_user_id_key UNIQUE (exam_id, user_id);


--
-- Name: course_exam_submissions course_exam_submissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_exam_submissions
    ADD CONSTRAINT course_exam_submissions_pkey PRIMARY KEY (id);


--
-- Name: course_exams course_exams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_exams
    ADD CONSTRAINT course_exams_pkey PRIMARY KEY (id);


--
-- Name: course_messages course_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_messages
    ADD CONSTRAINT course_messages_pkey PRIMARY KEY (id);


--
-- Name: course_participant_levels course_participant_levels_course_id_level_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_participant_levels
    ADD CONSTRAINT course_participant_levels_course_id_level_number_key UNIQUE (course_id, level_number);


--
-- Name: course_participant_levels course_participant_levels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_participant_levels
    ADD CONSTRAINT course_participant_levels_pkey PRIMARY KEY (id);


--
-- Name: course_ratings course_ratings_course_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_ratings
    ADD CONSTRAINT course_ratings_course_id_user_id_key UNIQUE (course_id, user_id);


--
-- Name: course_ratings course_ratings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_ratings
    ADD CONSTRAINT course_ratings_pkey PRIMARY KEY (id);


--
-- Name: course_schedule course_schedule_course_id_day_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_schedule
    ADD CONSTRAINT course_schedule_course_id_day_number_key UNIQUE (course_id, day_number);


--
-- Name: course_schedule course_schedule_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_schedule
    ADD CONSTRAINT course_schedule_pkey PRIMARY KEY (id);


--
-- Name: course_task_templates course_task_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_task_templates
    ADD CONSTRAINT course_task_templates_pkey PRIMARY KEY (id);


--
-- Name: course_templates course_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_templates
    ADD CONSTRAINT course_templates_pkey PRIMARY KEY (id);


--
-- Name: courses courses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_pkey PRIMARY KEY (id);


--
-- Name: daily_commitments daily_commitments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_commitments
    ADD CONSTRAINT daily_commitments_pkey PRIMARY KEY (id);


--
-- Name: daily_commitments daily_commitments_user_id_commitment_date_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_commitments
    ADD CONSTRAINT daily_commitments_user_id_commitment_date_key UNIQUE (user_id, commitment_date);


--
-- Name: enrollments enrollments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_pkey PRIMARY KEY (id);


--
-- Name: enrollments enrollments_user_id_course_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_user_id_course_id_key UNIQUE (user_id, course_id);


--
-- Name: exam_attempts exam_attempts_exam_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exam_attempts
    ADD CONSTRAINT exam_attempts_exam_id_user_id_key UNIQUE (exam_id, user_id);


--
-- Name: exam_attempts exam_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exam_attempts
    ADD CONSTRAINT exam_attempts_pkey PRIMARY KEY (id);


--
-- Name: exam_submissions exam_submissions_exam_id_user_id_attempt_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exam_submissions
    ADD CONSTRAINT exam_submissions_exam_id_user_id_attempt_number_key UNIQUE (exam_id, user_id, attempt_number);


--
-- Name: exam_submissions exam_submissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exam_submissions
    ADD CONSTRAINT exam_submissions_pkey PRIMARY KEY (id);


--
-- Name: exams exams_course_id_day_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exams
    ADD CONSTRAINT exams_course_id_day_number_key UNIQUE (course_id, day_number);


--
-- Name: exams exams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exams
    ADD CONSTRAINT exams_pkey PRIMARY KEY (id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: parent_child_relationships parent_child_relationships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parent_child_relationships
    ADD CONSTRAINT parent_child_relationships_pkey PRIMARY KEY (parent_id, child_id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: performance_evaluations performance_evaluations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.performance_evaluations
    ADD CONSTRAINT performance_evaluations_pkey PRIMARY KEY (id);


--
-- Name: performance_evaluations performance_evaluations_user_id_course_id_evaluation_date_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.performance_evaluations
    ADD CONSTRAINT performance_evaluations_user_id_course_id_evaluation_date_key UNIQUE (user_id, course_id, evaluation_date);


--
-- Name: submissions submissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.submissions
    ADD CONSTRAINT submissions_pkey PRIMARY KEY (id);


--
-- Name: submissions submissions_task_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.submissions
    ADD CONSTRAINT submissions_task_id_user_id_key UNIQUE (task_id, user_id);


--
-- Name: system_announcements system_announcements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_announcements
    ADD CONSTRAINT system_announcements_pkey PRIMARY KEY (id);


--
-- Name: tasks tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_pkey PRIMARY KEY (id);


--
-- Name: user_edit_requests user_edit_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_edit_requests
    ADD CONSTRAINT user_edit_requests_pkey PRIMARY KEY (id);


--
-- Name: user_relationships user_relationships_parent_id_child_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_relationships
    ADD CONSTRAINT user_relationships_parent_id_child_id_key UNIQUE (parent_id, child_id);


--
-- Name: user_relationships user_relationships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_relationships
    ADD CONSTRAINT user_relationships_pkey PRIMARY KEY (id);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: verification_tokens verification_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verification_tokens
    ADD CONSTRAINT verification_tokens_pkey PRIMARY KEY (id);


--
-- Name: verification_tokens verification_tokens_user_id_type_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verification_tokens
    ADD CONSTRAINT verification_tokens_user_id_type_key UNIQUE (user_id, type);


--
-- Name: worker_attendance worker_attendance_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_attendance
    ADD CONSTRAINT worker_attendance_pkey PRIMARY KEY (id);


--
-- Name: worker_attendance worker_attendance_worker_id_date_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_attendance
    ADD CONSTRAINT worker_attendance_worker_id_date_key UNIQUE (worker_id, date);


--
-- Name: worker_department_assignments worker_department_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_department_assignments
    ADD CONSTRAINT worker_department_assignments_pkey PRIMARY KEY (id);


--
-- Name: worker_department_assignments worker_department_assignments_worker_id_department_id_start_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_department_assignments
    ADD CONSTRAINT worker_department_assignments_worker_id_department_id_start_key UNIQUE (worker_id, department_id, start_date);


--
-- Name: worker_departments worker_departments_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_departments
    ADD CONSTRAINT worker_departments_name_key UNIQUE (name);


--
-- Name: worker_departments worker_departments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_departments
    ADD CONSTRAINT worker_departments_pkey PRIMARY KEY (id);


--
-- Name: worker_notifications worker_notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_notifications
    ADD CONSTRAINT worker_notifications_pkey PRIMARY KEY (id);


--
-- Name: worker_performance worker_performance_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_performance
    ADD CONSTRAINT worker_performance_pkey PRIMARY KEY (id);


--
-- Name: worker_reports worker_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_reports
    ADD CONSTRAINT worker_reports_pkey PRIMARY KEY (id);


--
-- Name: worker_schedule worker_schedule_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_schedule
    ADD CONSTRAINT worker_schedule_pkey PRIMARY KEY (id);


--
-- Name: worker_skills worker_skills_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_skills
    ADD CONSTRAINT worker_skills_pkey PRIMARY KEY (id);


--
-- Name: worker_tasks worker_tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_tasks
    ADD CONSTRAINT worker_tasks_pkey PRIMARY KEY (id);


--
-- Name: worker_timesheet worker_timesheet_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_timesheet
    ADD CONSTRAINT worker_timesheet_pkey PRIMARY KEY (id);


--
-- Name: idx_attendance_course_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attendance_course_id ON public.attendance USING btree (course_id);


--
-- Name: idx_attendance_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attendance_date ON public.attendance USING btree (date);


--
-- Name: idx_attendance_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attendance_user_id ON public.attendance USING btree (user_id);


--
-- Name: idx_course_auto_fill_course; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_auto_fill_course ON public.course_auto_fill_templates USING btree (course_id);


--
-- Name: idx_course_auto_launch_course; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_auto_launch_course ON public.course_auto_launch_log USING btree (course_id);


--
-- Name: idx_course_auto_launch_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_auto_launch_date ON public.course_auto_launch_log USING btree (launched_at);


--
-- Name: idx_course_exam_questions_exam; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_exam_questions_exam ON public.course_exam_questions USING btree (exam_id);


--
-- Name: idx_course_exam_submissions_exam; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_exam_submissions_exam ON public.course_exam_submissions USING btree (exam_id);


--
-- Name: idx_course_exam_submissions_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_exam_submissions_user ON public.course_exam_submissions USING btree (user_id);


--
-- Name: idx_course_exams_course; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_exams_course ON public.course_exams USING btree (course_id);


--
-- Name: idx_course_exams_schedule; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_exams_schedule ON public.course_exams USING btree (schedule_day_id);


--
-- Name: idx_course_messages_course; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_messages_course ON public.course_messages USING btree (course_id);


--
-- Name: idx_course_messages_course_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_messages_course_id ON public.course_messages USING btree (course_id);


--
-- Name: idx_course_messages_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_messages_created ON public.course_messages USING btree (created_at);


--
-- Name: idx_course_messages_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_messages_parent ON public.course_messages USING btree (parent_message_id);


--
-- Name: idx_course_messages_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_messages_user ON public.course_messages USING btree (user_id);


--
-- Name: idx_course_participant_levels_course; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_participant_levels_course ON public.course_participant_levels USING btree (course_id);


--
-- Name: idx_course_participant_levels_course_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_participant_levels_course_id ON public.course_participant_levels USING btree (course_id);


--
-- Name: idx_course_participant_levels_level; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_participant_levels_level ON public.course_participant_levels USING btree (level_number);


--
-- Name: idx_course_ratings_course_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_ratings_course_id ON public.course_ratings USING btree (course_id);


--
-- Name: idx_course_schedule_course_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_schedule_course_id ON public.course_schedule USING btree (course_id);


--
-- Name: idx_course_schedule_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_schedule_date ON public.course_schedule USING btree (scheduled_date);


--
-- Name: idx_course_schedule_meeting_times; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_course_schedule_meeting_times ON public.course_schedule USING btree (meeting_start_time, meeting_end_time);


--
-- Name: idx_courses_created_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_courses_created_by ON public.courses USING btree (created_by);


--
-- Name: idx_courses_is_launched; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_courses_is_launched ON public.courses USING btree (is_launched);


--
-- Name: idx_courses_is_public; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_courses_is_public ON public.courses USING btree (is_public);


--
-- Name: idx_courses_is_published; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_courses_is_published ON public.courses USING btree (is_published);


--
-- Name: idx_courses_launched; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_courses_launched ON public.courses USING btree (is_launched);


--
-- Name: idx_courses_published; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_courses_published ON public.courses USING btree (is_published);


--
-- Name: idx_courses_start_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_courses_start_date ON public.courses USING btree (start_date);


--
-- Name: idx_courses_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_courses_status ON public.courses USING btree (status);


--
-- Name: idx_courses_status_published; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_courses_status_published ON public.courses USING btree (status, is_published);


--
-- Name: idx_courses_teacher_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_courses_teacher_id ON public.courses USING btree (teacher_id);


--
-- Name: idx_courses_updated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_courses_updated_at ON public.courses USING btree (updated_at);


--
-- Name: idx_enrollments_course_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_enrollments_course_id ON public.enrollments USING btree (course_id);


--
-- Name: idx_enrollments_course_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_enrollments_course_status ON public.enrollments USING btree (course_id, status);


--
-- Name: idx_enrollments_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_enrollments_status ON public.enrollments USING btree (status);


--
-- Name: idx_enrollments_status_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_enrollments_status_user ON public.enrollments USING btree (status, user_id);


--
-- Name: idx_enrollments_user_course; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_enrollments_user_course ON public.enrollments USING btree (user_id, course_id);


--
-- Name: idx_enrollments_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_enrollments_user_id ON public.enrollments USING btree (user_id);


--
-- Name: idx_enrollments_user_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_enrollments_user_status ON public.enrollments USING btree (user_id, status);


--
-- Name: idx_exam_attempts_exam_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_exam_attempts_exam_id ON public.exam_attempts USING btree (exam_id);


--
-- Name: idx_exam_attempts_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_exam_attempts_user_id ON public.exam_attempts USING btree (user_id);


--
-- Name: idx_exam_submissions_exam; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_exam_submissions_exam ON public.exam_submissions USING btree (exam_id);


--
-- Name: idx_exam_submissions_submitted; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_exam_submissions_submitted ON public.exam_submissions USING btree (submitted_at);


--
-- Name: idx_exam_submissions_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_exam_submissions_user ON public.exam_submissions USING btree (user_id);


--
-- Name: idx_exams_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_exams_active ON public.exams USING btree (is_active);


--
-- Name: idx_exams_course; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_exams_course ON public.exams USING btree (course_id);


--
-- Name: idx_exams_course_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_exams_course_active ON public.exams USING btree (course_id, is_active);


--
-- Name: idx_exams_day; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_exams_day ON public.exams USING btree (day_number);


--
-- Name: idx_exams_day_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_exams_day_number ON public.exams USING btree (course_id, day_number);


--
-- Name: idx_messages_recipient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_messages_recipient_id ON public.messages USING btree (recipient_id);


--
-- Name: idx_messages_sent_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_messages_sent_at ON public.messages USING btree (sent_at);


--
-- Name: idx_notifications_user_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notifications_user_created ON public.notifications USING btree (user_id, created_at DESC);


--
-- Name: idx_notifications_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notifications_user_id ON public.notifications USING btree (user_id);


--
-- Name: idx_notifications_user_read; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notifications_user_read ON public.notifications USING btree (user_id, is_read);


--
-- Name: idx_parent_child_child; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_parent_child_child ON public.parent_child_relationships USING btree (child_id);


--
-- Name: idx_parent_child_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_parent_child_parent ON public.parent_child_relationships USING btree (parent_id);


--
-- Name: idx_payments_enrollment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payments_enrollment ON public.payments USING btree (enrollment_id);


--
-- Name: idx_payments_enrollment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payments_enrollment_id ON public.payments USING btree (enrollment_id);


--
-- Name: idx_payments_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payments_status ON public.payments USING btree (status);


--
-- Name: idx_performance_evaluations_user_course; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_performance_evaluations_user_course ON public.performance_evaluations USING btree (user_id, course_id);


--
-- Name: idx_submissions_task_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_submissions_task_id ON public.submissions USING btree (task_id);


--
-- Name: idx_submissions_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_submissions_user_id ON public.submissions USING btree (user_id);


--
-- Name: idx_tasks_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_active ON public.tasks USING btree (is_active);


--
-- Name: idx_tasks_assigned_to; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_assigned_to ON public.tasks USING btree (assigned_to);


--
-- Name: idx_tasks_course_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_course_id ON public.tasks USING btree (course_id);


--
-- Name: idx_tasks_course_level; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_course_level ON public.tasks USING btree (course_id, level_number);


--
-- Name: idx_tasks_schedule_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_schedule_id ON public.tasks USING btree (schedule_id);


--
-- Name: idx_user_edit_requests_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_edit_requests_status ON public.user_edit_requests USING btree (status);


--
-- Name: idx_user_edit_requests_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_edit_requests_user_id ON public.user_edit_requests USING btree (user_id);


--
-- Name: idx_user_relationships_child_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_relationships_child_id ON public.user_relationships USING btree (child_id);


--
-- Name: idx_user_relationships_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_relationships_parent_id ON public.user_relationships USING btree (parent_id);


--
-- Name: idx_users_account_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_account_status ON public.users USING btree (account_status);


--
-- Name: idx_users_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_email ON public.users USING btree (email);


--
-- Name: idx_users_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_phone ON public.users USING btree (phone);


--
-- Name: idx_users_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_role ON public.users USING btree (role);


--
-- Name: idx_users_role_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_role_status ON public.users USING btree (role, account_status);


--
-- Name: idx_verification_tokens_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_verification_tokens_token ON public.verification_tokens USING btree (token);


--
-- Name: idx_verification_tokens_user_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_verification_tokens_user_type ON public.verification_tokens USING btree (user_id, type);


--
-- Name: idx_worker_attendance_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_attendance_date ON public.worker_attendance USING btree (date);


--
-- Name: idx_worker_attendance_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_attendance_status ON public.worker_attendance USING btree (status);


--
-- Name: idx_worker_attendance_worker_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_attendance_worker_id ON public.worker_attendance USING btree (worker_id);


--
-- Name: idx_worker_dept_assignments_dept_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_dept_assignments_dept_id ON public.worker_department_assignments USING btree (department_id);


--
-- Name: idx_worker_dept_assignments_worker_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_dept_assignments_worker_id ON public.worker_department_assignments USING btree (worker_id);


--
-- Name: idx_worker_notifications_read_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_notifications_read_status ON public.worker_notifications USING btree (read_status);


--
-- Name: idx_worker_notifications_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_notifications_type ON public.worker_notifications USING btree (notification_type);


--
-- Name: idx_worker_notifications_worker_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_notifications_worker_id ON public.worker_notifications USING btree (worker_id);


--
-- Name: idx_worker_performance_period; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_performance_period ON public.worker_performance USING btree (evaluation_period_start, evaluation_period_end);


--
-- Name: idx_worker_performance_worker_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_performance_worker_id ON public.worker_performance USING btree (worker_id);


--
-- Name: idx_worker_reports_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_reports_date ON public.worker_reports USING btree (report_date);


--
-- Name: idx_worker_reports_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_reports_status ON public.worker_reports USING btree (status);


--
-- Name: idx_worker_reports_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_reports_type ON public.worker_reports USING btree (report_type);


--
-- Name: idx_worker_reports_worker_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_reports_worker_id ON public.worker_reports USING btree (worker_id);


--
-- Name: idx_worker_schedule_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_schedule_date ON public.worker_schedule USING btree (scheduled_date);


--
-- Name: idx_worker_schedule_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_schedule_status ON public.worker_schedule USING btree (status);


--
-- Name: idx_worker_schedule_worker_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_schedule_worker_id ON public.worker_schedule USING btree (worker_id);


--
-- Name: idx_worker_skills_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_skills_category ON public.worker_skills USING btree (skill_category);


--
-- Name: idx_worker_skills_worker_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_skills_worker_id ON public.worker_skills USING btree (worker_id);


--
-- Name: idx_worker_tasks_assigned_to; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_tasks_assigned_to ON public.worker_tasks USING btree (assigned_to);


--
-- Name: idx_worker_tasks_due_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_tasks_due_date ON public.worker_tasks USING btree (due_date);


--
-- Name: idx_worker_tasks_priority; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_tasks_priority ON public.worker_tasks USING btree (priority);


--
-- Name: idx_worker_tasks_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_tasks_status ON public.worker_tasks USING btree (status);


--
-- Name: idx_worker_timesheet_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_timesheet_date ON public.worker_timesheet USING btree (date);


--
-- Name: idx_worker_timesheet_month_year; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_timesheet_month_year ON public.worker_timesheet USING btree (month_year);


--
-- Name: idx_worker_timesheet_week_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_timesheet_week_start ON public.worker_timesheet USING btree (week_start);


--
-- Name: idx_worker_timesheet_worker_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_worker_timesheet_worker_id ON public.worker_timesheet USING btree (worker_id);


--
-- Name: course_management_view _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.course_management_view AS
 SELECT c.id,
    c.name,
    c.description,
    c.created_by,
    c.created_at,
    c.details,
    c.status,
    c.approved_by,
    c.approved_at,
    c.template_id,
    c.current_enrollment,
    c.min_enrollment,
    c.max_enrollment,
    c.duration_days,
    c.start_date,
    c.days_per_week,
    c.hours_per_day,
    c.content_outline,
    c.auto_launch_settings,
    c.participant_config,
    c.is_published,
    c.is_launched,
    c.launched_at,
    c.launch_date,
    u.full_name AS created_by_name,
    count(DISTINCT e.id) FILTER (WHERE (e.status = ANY (ARRAY['active'::public.enrollment_status, 'waiting_start'::public.enrollment_status]))) AS current_enrollment_count,
    count(DISTINCT e.id) FILTER (WHERE (e.status = 'pending_payment'::public.enrollment_status)) AS pending_payment_count,
    count(DISTINCT e.id) FILTER (WHERE (e.status = 'pending_approval'::public.enrollment_status)) AS pending_approval_count,
    count(DISTINCT e.id) FILTER (WHERE (e.status = 'waiting_start'::public.enrollment_status)) AS waiting_start_count,
    count(DISTINCT e.id) FILTER (WHERE (e.status = 'active'::public.enrollment_status)) AS active_enrollment_count,
    count(DISTINCT e.id) FILTER (WHERE (e.status = 'completed'::public.enrollment_status)) AS completed_enrollment_count,
        CASE
            WHEN ((c.status)::text = 'draft'::text) THEN '┘è┘à┘â┘ ╪د┘╪ز╪╣╪»┘è┘'::text
            WHEN (((c.status)::text = 'published'::text) AND (NOT c.is_launched)) THEN '╪ش╪د┘ç╪▓ ┘┘╪د┘╪╖┘╪د┘é'::text
            WHEN ((c.status)::text = 'active'::text) THEN '┘╪┤╪╖'::text
            WHEN ((c.status)::text = 'completed'::text) THEN '┘à┘â╪ز┘à┘'::text
            ELSE '╪║┘è╪▒ ┘à╪ص╪»╪»'::text
        END AS status_description
   FROM ((public.courses c
     LEFT JOIN public.users u ON ((c.created_by = u.id)))
     LEFT JOIN public.enrollments e ON ((c.id = e.course_id)))
  GROUP BY c.id, u.full_name;


--
-- Name: courses trigger_update_enrollment_states; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_update_enrollment_states AFTER UPDATE OF status ON public.courses FOR EACH ROW EXECUTE FUNCTION public.update_enrollment_states_on_course_change();


--
-- Name: announcements update_announcements_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_announcements_updated_at BEFORE UPDATE ON public.announcements FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: course_schedule update_course_schedule_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_course_schedule_updated_at BEFORE UPDATE ON public.course_schedule FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: courses update_courses_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_courses_updated_at BEFORE UPDATE ON public.courses FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: system_announcements update_system_announcements_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_system_announcements_updated_at BEFORE UPDATE ON public.system_announcements FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: users update_users_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: worker_attendance update_worker_attendance_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_worker_attendance_updated_at BEFORE UPDATE ON public.worker_attendance FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: worker_departments update_worker_departments_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_worker_departments_updated_at BEFORE UPDATE ON public.worker_departments FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: worker_department_assignments update_worker_dept_assignments_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_worker_dept_assignments_updated_at BEFORE UPDATE ON public.worker_department_assignments FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: worker_performance update_worker_performance_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_worker_performance_updated_at BEFORE UPDATE ON public.worker_performance FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: worker_reports update_worker_reports_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_worker_reports_updated_at BEFORE UPDATE ON public.worker_reports FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: worker_schedule update_worker_schedule_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_worker_schedule_updated_at BEFORE UPDATE ON public.worker_schedule FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: worker_skills update_worker_skills_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_worker_skills_updated_at BEFORE UPDATE ON public.worker_skills FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: worker_tasks update_worker_tasks_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_worker_tasks_updated_at BEFORE UPDATE ON public.worker_tasks FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: worker_timesheet update_worker_timesheet_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_worker_timesheet_updated_at BEFORE UPDATE ON public.worker_timesheet FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: announcements announcements_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcements
    ADD CONSTRAINT announcements_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: attendance attendance_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: attendance attendance_recorded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_recorded_by_fkey FOREIGN KEY (recorded_by) REFERENCES public.users(id);


--
-- Name: attendance attendance_schedule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_schedule_id_fkey FOREIGN KEY (schedule_id) REFERENCES public.course_schedule(id) ON DELETE CASCADE;


--
-- Name: attendance attendance_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: certificates certificates_enrollment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_enrollment_id_fkey FOREIGN KEY (enrollment_id) REFERENCES public.enrollments(id) ON DELETE CASCADE;


--
-- Name: course_auto_fill_templates course_auto_fill_templates_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_auto_fill_templates
    ADD CONSTRAINT course_auto_fill_templates_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: course_auto_launch_log course_auto_launch_log_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_auto_launch_log
    ADD CONSTRAINT course_auto_launch_log_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: course_daily_progress course_daily_progress_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_daily_progress
    ADD CONSTRAINT course_daily_progress_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: course_exam_questions course_exam_questions_exam_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_exam_questions
    ADD CONSTRAINT course_exam_questions_exam_id_fkey FOREIGN KEY (exam_id) REFERENCES public.course_exams(id) ON DELETE CASCADE;


--
-- Name: course_exam_submissions course_exam_submissions_exam_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_exam_submissions
    ADD CONSTRAINT course_exam_submissions_exam_id_fkey FOREIGN KEY (exam_id) REFERENCES public.course_exams(id) ON DELETE CASCADE;


--
-- Name: course_exam_submissions course_exam_submissions_graded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_exam_submissions
    ADD CONSTRAINT course_exam_submissions_graded_by_fkey FOREIGN KEY (graded_by) REFERENCES public.users(id);


--
-- Name: course_exam_submissions course_exam_submissions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_exam_submissions
    ADD CONSTRAINT course_exam_submissions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: course_exams course_exams_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_exams
    ADD CONSTRAINT course_exams_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: course_exams course_exams_schedule_day_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_exams
    ADD CONSTRAINT course_exams_schedule_day_id_fkey FOREIGN KEY (schedule_day_id) REFERENCES public.course_schedule(id) ON DELETE CASCADE;


--
-- Name: course_messages course_messages_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_messages
    ADD CONSTRAINT course_messages_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: course_messages course_messages_parent_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_messages
    ADD CONSTRAINT course_messages_parent_message_id_fkey FOREIGN KEY (parent_message_id) REFERENCES public.course_messages(id);


--
-- Name: course_messages course_messages_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_messages
    ADD CONSTRAINT course_messages_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: course_participant_levels course_participant_levels_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_participant_levels
    ADD CONSTRAINT course_participant_levels_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: course_ratings course_ratings_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_ratings
    ADD CONSTRAINT course_ratings_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: course_ratings course_ratings_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_ratings
    ADD CONSTRAINT course_ratings_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: course_schedule course_schedule_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_schedule
    ADD CONSTRAINT course_schedule_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: course_task_templates course_task_templates_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_task_templates
    ADD CONSTRAINT course_task_templates_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: course_templates course_templates_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.course_templates
    ADD CONSTRAINT course_templates_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: courses courses_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.users(id);


--
-- Name: courses courses_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: courses courses_teacher_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_teacher_id_fkey FOREIGN KEY (teacher_id) REFERENCES public.users(id);


--
-- Name: courses courses_template_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_template_id_fkey FOREIGN KEY (template_id) REFERENCES public.course_templates(id);


--
-- Name: daily_commitments daily_commitments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_commitments
    ADD CONSTRAINT daily_commitments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: enrollments enrollments_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: enrollments enrollments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: exam_attempts exam_attempts_exam_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exam_attempts
    ADD CONSTRAINT exam_attempts_exam_id_fkey FOREIGN KEY (exam_id) REFERENCES public.exams(id) ON DELETE CASCADE;


--
-- Name: exam_attempts exam_attempts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exam_attempts
    ADD CONSTRAINT exam_attempts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: exam_submissions exam_submissions_exam_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exam_submissions
    ADD CONSTRAINT exam_submissions_exam_id_fkey FOREIGN KEY (exam_id) REFERENCES public.exams(id) ON DELETE CASCADE;


--
-- Name: exam_submissions exam_submissions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exam_submissions
    ADD CONSTRAINT exam_submissions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: exams exams_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exams
    ADD CONSTRAINT exams_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: exams exams_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exams
    ADD CONSTRAINT exams_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: system_announcements fk_announcements_created_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_announcements
    ADD CONSTRAINT fk_announcements_created_by FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: messages messages_recipient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_recipient_id_fkey FOREIGN KEY (recipient_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: messages messages_sender_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: parent_child_relationships parent_child_relationships_child_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parent_child_relationships
    ADD CONSTRAINT parent_child_relationships_child_id_fkey FOREIGN KEY (child_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: parent_child_relationships parent_child_relationships_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parent_child_relationships
    ADD CONSTRAINT parent_child_relationships_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: payments payments_confirmed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_confirmed_by_fkey FOREIGN KEY (confirmed_by) REFERENCES public.users(id);


--
-- Name: payments payments_enrollment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_enrollment_id_fkey FOREIGN KEY (enrollment_id) REFERENCES public.enrollments(id) ON DELETE CASCADE;


--
-- Name: performance_evaluations performance_evaluations_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.performance_evaluations
    ADD CONSTRAINT performance_evaluations_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: performance_evaluations performance_evaluations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.performance_evaluations
    ADD CONSTRAINT performance_evaluations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: submissions submissions_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.submissions
    ADD CONSTRAINT submissions_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(id) ON DELETE CASCADE;


--
-- Name: submissions submissions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.submissions
    ADD CONSTRAINT submissions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: system_announcements system_announcements_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_announcements
    ADD CONSTRAINT system_announcements_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: tasks tasks_assigned_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_assigned_to_fkey FOREIGN KEY (assigned_to) REFERENCES public.users(id);


--
-- Name: tasks tasks_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id);


--
-- Name: tasks tasks_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: tasks tasks_schedule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_schedule_id_fkey FOREIGN KEY (schedule_id) REFERENCES public.course_schedule(id) ON DELETE CASCADE;


--
-- Name: user_edit_requests user_edit_requests_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_edit_requests
    ADD CONSTRAINT user_edit_requests_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES public.users(id);


--
-- Name: user_edit_requests user_edit_requests_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_edit_requests
    ADD CONSTRAINT user_edit_requests_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_relationships user_relationships_child_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_relationships
    ADD CONSTRAINT user_relationships_child_id_fkey FOREIGN KEY (child_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_relationships user_relationships_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_relationships
    ADD CONSTRAINT user_relationships_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: users users_reports_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_reports_to_fkey FOREIGN KEY (reports_to) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: verification_tokens verification_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verification_tokens
    ADD CONSTRAINT verification_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: worker_attendance worker_attendance_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_attendance
    ADD CONSTRAINT worker_attendance_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.users(id);


--
-- Name: worker_attendance worker_attendance_worker_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_attendance
    ADD CONSTRAINT worker_attendance_worker_id_fkey FOREIGN KEY (worker_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: worker_department_assignments worker_department_assignments_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_department_assignments
    ADD CONSTRAINT worker_department_assignments_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.worker_departments(id) ON DELETE CASCADE;


--
-- Name: worker_department_assignments worker_department_assignments_worker_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_department_assignments
    ADD CONSTRAINT worker_department_assignments_worker_id_fkey FOREIGN KEY (worker_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: worker_departments worker_departments_head_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_departments
    ADD CONSTRAINT worker_departments_head_id_fkey FOREIGN KEY (head_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: worker_notifications worker_notifications_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_notifications
    ADD CONSTRAINT worker_notifications_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: worker_notifications worker_notifications_related_schedule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_notifications
    ADD CONSTRAINT worker_notifications_related_schedule_id_fkey FOREIGN KEY (related_schedule_id) REFERENCES public.worker_schedule(id) ON DELETE SET NULL;


--
-- Name: worker_notifications worker_notifications_related_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_notifications
    ADD CONSTRAINT worker_notifications_related_task_id_fkey FOREIGN KEY (related_task_id) REFERENCES public.worker_tasks(id) ON DELETE SET NULL;


--
-- Name: worker_notifications worker_notifications_worker_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_notifications
    ADD CONSTRAINT worker_notifications_worker_id_fkey FOREIGN KEY (worker_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: worker_performance worker_performance_evaluator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_performance
    ADD CONSTRAINT worker_performance_evaluator_id_fkey FOREIGN KEY (evaluator_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: worker_performance worker_performance_worker_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_performance
    ADD CONSTRAINT worker_performance_worker_id_fkey FOREIGN KEY (worker_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: worker_reports worker_reports_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_reports
    ADD CONSTRAINT worker_reports_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES public.users(id);


--
-- Name: worker_reports worker_reports_submitted_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_reports
    ADD CONSTRAINT worker_reports_submitted_to_fkey FOREIGN KEY (submitted_to) REFERENCES public.users(id);


--
-- Name: worker_reports worker_reports_worker_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_reports
    ADD CONSTRAINT worker_reports_worker_id_fkey FOREIGN KEY (worker_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: worker_schedule worker_schedule_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_schedule
    ADD CONSTRAINT worker_schedule_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: worker_schedule worker_schedule_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_schedule
    ADD CONSTRAINT worker_schedule_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.worker_tasks(id) ON DELETE SET NULL;


--
-- Name: worker_schedule worker_schedule_worker_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_schedule
    ADD CONSTRAINT worker_schedule_worker_id_fkey FOREIGN KEY (worker_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: worker_skills worker_skills_verified_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_skills
    ADD CONSTRAINT worker_skills_verified_by_fkey FOREIGN KEY (verified_by) REFERENCES public.users(id);


--
-- Name: worker_skills worker_skills_worker_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_skills
    ADD CONSTRAINT worker_skills_worker_id_fkey FOREIGN KEY (worker_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: worker_tasks worker_tasks_assigned_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_tasks
    ADD CONSTRAINT worker_tasks_assigned_by_fkey FOREIGN KEY (assigned_by) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: worker_tasks worker_tasks_assigned_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_tasks
    ADD CONSTRAINT worker_tasks_assigned_to_fkey FOREIGN KEY (assigned_to) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: worker_timesheet worker_timesheet_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_timesheet
    ADD CONSTRAINT worker_timesheet_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.users(id);


--
-- Name: worker_timesheet worker_timesheet_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_timesheet
    ADD CONSTRAINT worker_timesheet_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.worker_tasks(id) ON DELETE SET NULL;


--
-- Name: worker_timesheet worker_timesheet_worker_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.worker_timesheet
    ADD CONSTRAINT worker_timesheet_worker_id_fkey FOREIGN KEY (worker_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

