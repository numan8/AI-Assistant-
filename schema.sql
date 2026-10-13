-- Run in Supabase SQL Editor. Never put service-role keys in Streamlit.
create extension if not exists pgcrypto;
create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 email text not null, role text not null default 'student' check (role in ('student','teacher')),
 created_at timestamptz not null default now()
);
create table if not exists public.assessments (
 id uuid primary key default gen_random_uuid(),
 teacher_id uuid not null references public.profiles(id),
 title text not null, kind text not null check(kind in ('quiz','assignment')),
 question text not null, answer_key text, rubric text, max_score numeric not null check(max_score > 0),
 created_at timestamptz not null default now()
);
create table if not exists public.submissions (
 id uuid primary key default gen_random_uuid(),
 assessment_id uuid not null references public.assessments(id),
 student_id uuid not null references public.profiles(id),
 answer text, file_path text,
 proposed_score numeric, proposed_feedback text,
 approved_score numeric, approved_feedback text,
 approved boolean not null default false,
 submitted_at timestamptz not null default now(),
 unique(assessment_id,student_id)
);
create or replace function public.create_profile() returns trigger language plpgsql security definer set search_path = '' as $$
begin
 insert into public.profiles(id,email,role) values(new.id,coalesce(new.email,''),'student');
 return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.create_profile();
-- Backfill users created before the trigger was installed.
insert into public.profiles(id,email,role)
select id,coalesce(email,''),'student' from auth.users on conflict (id) do nothing;
create or replace function public.is_teacher() returns boolean language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.profiles where id = (select auth.uid()) and role='teacher');
$$;
create or replace function public.owns_assessment(aid uuid) returns boolean language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.assessments where id=aid and teacher_id=(select auth.uid()));
$$;
alter table public.profiles enable row level security;
alter table public.assessments enable row level security;
alter table public.submissions enable row level security;
drop policy if exists profiles_self on public.profiles;
create policy profiles_self on public.profiles for select to authenticated using (id=(select auth.uid()));
drop policy if exists assessments_read on public.assessments;
create policy assessments_read on public.assessments for select to authenticated using (true);
drop policy if exists assessments_create on public.assessments;
create policy assessments_create on public.assessments for insert to authenticated with check (teacher_id=(select auth.uid()) and (select public.is_teacher()));
drop policy if exists assessments_update on public.assessments;
create policy assessments_update on public.assessments for update to authenticated using (teacher_id=(select auth.uid()) and (select public.is_teacher())) with check (teacher_id=(select auth.uid()) and (select public.is_teacher()));
-- Students cannot write grading columns: submissions are created through a restricted RPC.
drop policy if exists submissions_read on public.submissions;
create policy submissions_read on public.submissions for select to authenticated using (student_id=(select auth.uid()) or (select public.owns_assessment(assessment_id)));
drop policy if exists submissions_teacher_update on public.submissions;
create policy submissions_teacher_update on public.submissions for update to authenticated using ((select public.owns_assessment(assessment_id))) with check ((select public.owns_assessment(assessment_id)));
revoke insert, update, delete on public.submissions from anon, authenticated;
grant select on public.submissions to authenticated;
-- Expose only approved student grading fields via a separate RPC; do not grant student direct SELECT of submissions.
drop policy if exists submissions_read on public.submissions;
create policy submissions_read on public.submissions for select to authenticated using ((select public.owns_assessment(assessment_id)));
create or replace function public.submit_work(p_assessment_id uuid, p_answer text, p_file_path text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare sid uuid; v_kind text;
begin
 if (select auth.uid()) is null then raise exception 'Not authenticated'; end if;
 if not exists(select 1 from public.profiles where id=(select auth.uid()) and role='student') then raise exception 'Student account required'; end if;
 select kind into v_kind from public.assessments where id=p_assessment_id;
 if v_kind is null then raise exception 'Assessment not found'; end if;
 if v_kind='assignment' and p_file_path is null and coalesce(trim(p_answer),'')='' then raise exception 'Submission is empty'; end if;
 insert into public.submissions(assessment_id,student_id,answer,file_path)
 values(p_assessment_id,(select auth.uid()),p_answer,p_file_path) returning id into sid;
 return sid;
end; $$;
create or replace function public.my_results()
returns table(assessment_title text, kind text, submitted_at timestamptz, approved boolean, score numeric, max_score numeric, feedback text)
language sql stable security definer set search_path = '' as $$
 select a.title,a.kind,s.submitted_at,s.approved,
 case when s.approved then s.approved_score else null end,
 a.max_score,case when s.approved then s.approved_feedback else null end
 from public.submissions s join public.assessments a on a.id=s.assessment_id
 where s.student_id=(select auth.uid()) order by s.submitted_at desc;
$$;
create or replace function public.teacher_grade(p_submission_id uuid,p_score numeric,p_feedback text,p_approve boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare mx numeric;
begin
 select a.max_score into mx from public.submissions s join public.assessments a on a.id=s.assessment_id
 where s.id=p_submission_id and a.teacher_id=(select auth.uid()) and (select public.is_teacher());
 if mx is null then raise exception 'Not authorized'; end if;
 if p_score is null or p_score<0 or p_score>mx then raise exception 'Score outside permitted range'; end if;
 update public.submissions set proposed_score=p_score, proposed_feedback=p_feedback,
 approved=p_approve, approved_score=case when p_approve then p_score else null end,
 approved_feedback=case when p_approve then p_feedback else null end
 where id=p_submission_id;
end; $$;
revoke all on function public.submit_work(uuid,text,text) from public;
revoke all on function public.my_results() from public;
revoke all on function public.teacher_grade(uuid,numeric,text,boolean) from public;
grant execute on function public.submit_work(uuid,text,text) to authenticated;
grant execute on function public.my_results() to authenticated;
grant execute on function public.teacher_grade(uuid,numeric,text,boolean) to authenticated;
-- Private storage bucket; only the student may upload under their UID; teachers may read files belonging to their assessments.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('assignments','assignments',false,10485760,array['application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document','text/plain'])
on conflict(id) do update set public=false;
drop policy if exists student_upload on storage.objects;
create policy student_upload on storage.objects for insert to authenticated
with check(bucket_id='assignments' and (storage.foldername(name))[1]=(select auth.uid())::text
 and exists(select 1 from public.profiles where id=(select auth.uid()) and role='student'));
drop policy if exists teacher_file_read on storage.objects;
create policy teacher_file_read on storage.objects for select to authenticated
using(bucket_id='assignments' and exists(
 select 1 from public.submissions s join public.assessments a on a.id=s.assessment_id
 where s.file_path=name and a.teacher_id=(select auth.uid())
));
-- IMPORTANT: promote your own teacher account manually in SQL Editor AFTER signing up:
-- update public.profiles set role='teacher' where email='your-teacher-email@example.com';
